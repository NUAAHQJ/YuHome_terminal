#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iterator>
#include <mutex>
#include <netinet/in.h>
#include <node_api.h>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <thread>
#include <unordered_map>
#include <unistd.h>
#include <vector>

#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"

extern "C" {
#include "broker.h"
#include "nng/supplemental/nanolib/conf.h"
#include "nng/supplemental/nanolib/cJSON.h"
}

// SDK 23 fortifies FD_SET through __fd_chk, while the Dayu system image does
// not export that helper. MbedTLS validates descriptors before FD_SET, so this
// weak compatibility definition preserves the same bounds check.
extern "C" __attribute__((weak)) void __fd_chk(int fd)
{
    if (fd < 0 || fd >= FD_SETSIZE) {
        std::abort();
    }
}

namespace {

constexpr size_t MAX_REQUEST_BYTES = 256 * 1024;
constexpr size_t MAX_COMMANDS_PER_DEVICE = 20;
constexpr int64_t PROTOCOL_COMMAND_TTL_MS = 10 * 1000;

int64_t NowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

std::string JsonEscape(const std::string &value)
{
    std::string escaped;
    escaped.reserve(value.size() + 16);
    for (char ch : value) {
        switch (ch) {
            case '\\': escaped += "\\\\"; break;
            case '"': escaped += "\\\""; break;
            case '\n': escaped += "\\n"; break;
            case '\r': escaped += "\\r"; break;
            case '\t': escaped += "\\t"; break;
            default: escaped += ch; break;
        }
    }
    return escaped;
}

std::string UrlDecode(const std::string &value)
{
    std::string decoded;
    decoded.reserve(value.size());
    for (size_t i = 0; i < value.size(); ++i) {
        if (value[i] == '%' && i + 2 < value.size()) {
            const std::string hex = value.substr(i + 1, 2);
            char *end = nullptr;
            const long parsed = std::strtol(hex.c_str(), &end, 16);
            if (end != nullptr && *end == '\0') {
                decoded += static_cast<char>(parsed);
                i += 2;
                continue;
            }
        }
        decoded += value[i] == '+' ? ' ' : value[i];
    }
    return decoded;
}

std::string QueryParam(const std::string &target, const std::string &name)
{
    const size_t queryAt = target.find('?');
    if (queryAt == std::string::npos) {
        return "";
    }
    const std::string query = target.substr(queryAt + 1);
    const std::string prefix = name + "=";
    size_t start = 0;
    while (start <= query.size()) {
        const size_t end = query.find('&', start);
        const std::string item = query.substr(start, end == std::string::npos ? std::string::npos : end - start);
        if (item.rfind(prefix, 0) == 0) {
            return UrlDecode(item.substr(prefix.size()));
        }
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }
    return "";
}

bool IsValidDeviceId(const std::string &deviceId)
{
    if (deviceId.size() < 3 || deviceId.size() > 64 || deviceId == "auto") {
        return false;
    }
    for (size_t i = 0; i < deviceId.size(); ++i) {
        const char ch = deviceId[i];
        const bool valid = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
            (ch >= '0' && ch <= '9') || ch == '_' || ch == '-';
        if (!valid || (i == 0 && (ch == '_' || ch == '-'))) {
            return false;
        }
    }
    return true;
}

bool TopicMatchesDevice(const std::string &topic, const std::string &deviceId)
{
    const std::string devicePrefix = "device/" + deviceId + "/";
    const std::string commandTopic = "dayu/cmd/" + deviceId;
    const std::string keyTopic = "key/ecdh/pub/" + deviceId;
    return topic.rfind(devicePrefix, 0) == 0 || topic == commandTopic || topic == keyTopic ||
        (deviceId == "esp32" && (topic == "dayu/cmd" || topic.rfind("esp32/", 0) == 0));
}

int32_t Base64DecodedBytes(const std::string &value)
{
    if (value.empty()) {
        return 0;
    }
    int32_t padding = 0;
    if (value.size() >= 1 && value[value.size() - 1] == '=') {
        ++padding;
    }
    if (value.size() >= 2 && value[value.size() - 2] == '=') {
        ++padding;
    }
    return static_cast<int32_t>((value.size() / 4) * 3) - padding;
}

bool ReadJsonString(cJSON *root, const char *name, std::string &value)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(root, name);
    if (!cJSON_IsString(item) || item->valuestring == nullptr) {
        return false;
    }
    value = item->valuestring;
    return true;
}

struct GatewayEvent {
    std::string type;
    std::string body;
    int64_t timestamp = 0;
};

struct GatewayCommand {
    std::string id;
    std::string topic;
    std::string payloadBase64;
    int32_t bytes = 0;
    int64_t timestamp = 0;
};

class LocalGateway {
public:
    static LocalGateway &Instance()
    {
        static LocalGateway instance;
        return instance;
    }

    bool Start(uint16_t port, std::string &error)
    {
        if (running_.load()) {
            return true;
        }
        const int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            error = "socket failed";
            return false;
        }
        int reuse = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        sockaddr_in address {};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        address.sin_port = htons(port);
        if (bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
            error = std::string("bind failed: ") + std::strerror(errno);
            close(fd);
            return false;
        }
        if (listen(fd, 16) != 0) {
            error = std::string("listen failed: ") + std::strerror(errno);
            close(fd);
            return false;
        }
        listenFd_ = fd;
        port_ = port;
        running_.store(true);
        acceptThread_ = std::thread([this]() { AcceptLoop(); });
        return true;
    }

    void Stop()
    {
        if (running_.exchange(false)) {
            const int fd = listenFd_;
            listenFd_ = -1;
            if (fd >= 0) {
                shutdown(fd, SHUT_RDWR);
                close(fd);
            }
            if (acceptThread_.joinable()) {
                acceptThread_.join();
            }
        }
        if (httpsRunning_.exchange(false)) {
            mbedtls_net_free(&httpsListen_);
            if (httpsThread_.joinable()) {
                httpsThread_.join();
            }
            FreeHttps();
        }
    }

    bool IsRunning() const { return running_.load(); }
    uint16_t Port() const { return port_; }
    uint64_t RequestCount() const { return requestCount_.load(); }
    bool IsMqttRunning() const { return mqttRunning_.load(); }
    bool IsHttpsRunning() const { return httpsRunning_.load(); }
    uint16_t HttpsPort() const { return httpsPort_; }

    bool StartHttps(uint16_t port, const std::string &certificate,
        const std::string &privateKey, std::string &error)
    {
        if (httpsRunning_.load()) {
            return true;
        }
        if (certificate.empty() || privateKey.empty()) {
            error = "HTTPS certificate or private key is empty";
            return false;
        }
        mbedtls_net_init(&httpsListen_);
        mbedtls_ssl_config_init(&httpsConfig_);
        mbedtls_x509_crt_init(&httpsCertificate_);
        mbedtls_pk_init(&httpsPrivateKey_);
        mbedtls_entropy_init(&httpsEntropy_);
        mbedtls_ctr_drbg_init(&httpsCtrDrbg_);
        const char *personalization = "dayu-local-https";
        int result = mbedtls_ctr_drbg_seed(&httpsCtrDrbg_, mbedtls_entropy_func, &httpsEntropy_,
            reinterpret_cast<const unsigned char *>(personalization), std::strlen(personalization));
        if (result == 0) {
            result = mbedtls_x509_crt_parse(&httpsCertificate_,
                reinterpret_cast<const unsigned char *>(certificate.c_str()), certificate.size() + 1);
        }
        if (result == 0) {
            result = mbedtls_pk_parse_key(&httpsPrivateKey_,
                reinterpret_cast<const unsigned char *>(privateKey.c_str()), privateKey.size() + 1,
                nullptr, 0, mbedtls_ctr_drbg_random, &httpsCtrDrbg_);
        }
        if (result == 0) {
            result = mbedtls_ssl_config_defaults(&httpsConfig_, MBEDTLS_SSL_IS_SERVER,
                MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
        }
        if (result == 0) {
            // The HTTPS listener handles several ESP32 clients concurrently. The bundled
            // Mbed TLS build has no threading layer, so serialize access to the shared DRBG.
            mbedtls_ssl_conf_rng(&httpsConfig_, HttpsRandom, this);
            result = mbedtls_ssl_conf_own_cert(&httpsConfig_, &httpsCertificate_, &httpsPrivateKey_);
        }
        const std::string portText = std::to_string(port);
        if (result == 0) {
            result = mbedtls_net_bind(&httpsListen_, "0.0.0.0", portText.c_str(), MBEDTLS_NET_PROTO_TCP);
        }
        if (result != 0) {
            error = "HTTPS TLS initialization failed: " + std::to_string(result);
            FreeHttps();
            return false;
        }
        httpsPort_ = port;
        httpsRunning_.store(true);
        httpsThread_ = std::thread([this]() { HttpsAcceptLoop(); });
        return true;
    }

    bool StartMqtt(uint16_t port, uint16_t tlsPort, const std::string &certificate,
        const std::string &privateKey, std::string &error)
    {
        if (mqttRunning_.load()) {
            return true;
        }
        if (port != 1883) {
            error = "embedded NanoMQ currently uses port 1883";
            return false;
        }
        conf *brokerConfig = static_cast<conf *>(nng_zalloc(sizeof(conf)));
        if (brokerConfig == nullptr) {
            error = "cannot allocate NanoMQ configuration";
            return false;
        }
        conf_init(brokerConfig);
        if (tlsPort > 0 && !certificate.empty() && !privateKey.empty()) {
            const std::string tlsUrl = "tls+nmq-tcp://0.0.0.0:" + std::to_string(tlsPort);
            brokerConfig->tls.enable = true;
            brokerConfig->tls.url = nng_strdup(tlsUrl.c_str());
            brokerConfig->tls.cert = nng_strdup(certificate.c_str());
            brokerConfig->tls.key = nng_strdup(privateKey.c_str());
            brokerConfig->tls.verify_peer = false;
            brokerConfig->tls.set_fail = false;
        }
        mqttRunning_.store(true);
        std::thread([this, brokerConfig]() {
            broker_start_with_conf(brokerConfig);
            mqttRunning_.store(false);
        }).detach();
        return true;
    }

    std::string Enqueue(const std::string &deviceId, const std::string &topic,
        const std::string &payloadBase64, int32_t bytes)
    {
        GatewayCommand command;
        command.timestamp = NowMs();
        command.id = std::to_string(command.timestamp) + "-" + std::to_string(++commandSequence_);
        command.topic = topic;
        command.payloadBase64 = payloadBase64;
        command.bytes = bytes;
        std::lock_guard<std::mutex> lock(mutex_);
        auto &queue = commands_[deviceId];
        if (bytes >= 64 && bytes <= 69) {
            for (auto it = queue.begin(); it != queue.end();) {
                it = it->bytes >= 64 && it->bytes <= 69 ? queue.erase(it) : std::next(it);
            }
        }
        const std::string commandId = command.id;
        queue.push_back(std::move(command));
        while (queue.size() > MAX_COMMANDS_PER_DEVICE) {
            queue.pop_front();
        }
        return commandId;
    }

    std::vector<GatewayEvent> DrainEvents()
    {
        std::vector<GatewayEvent> result;
        std::lock_guard<std::mutex> lock(mutex_);
        while (!events_.empty()) {
            result.push_back(std::move(events_.front()));
            events_.pop_front();
        }
        return result;
    }

private:
    static int HttpsRandom(void *context, unsigned char *output, size_t length)
    {
        auto *gateway = static_cast<LocalGateway *>(context);
        std::lock_guard<std::mutex> lock(gateway->httpsRngMutex_);
        return mbedtls_ctr_drbg_random(&gateway->httpsCtrDrbg_, output, length);
    }

    LocalGateway() = default;
    ~LocalGateway() { Stop(); }
    LocalGateway(const LocalGateway &) = delete;
    LocalGateway &operator=(const LocalGateway &) = delete;

    void AcceptLoop()
    {
        while (running_.load()) {
            sockaddr_in peer {};
            socklen_t peerLength = sizeof(peer);
            const int client = accept(listenFd_, reinterpret_cast<sockaddr *>(&peer), &peerLength);
            if (client < 0) {
                if (running_.load()) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                }
                continue;
            }
            std::thread([this, client]() {
                HandleClient(client);
                shutdown(client, SHUT_RDWR);
                close(client);
            }).detach();
        }
    }

    void HttpsAcceptLoop()
    {
        while (httpsRunning_.load()) {
            auto *client = new mbedtls_net_context;
            mbedtls_net_init(client);
            const int accepted = mbedtls_net_accept(&httpsListen_, client, nullptr, 0, nullptr);
            if (accepted != 0) {
                delete client;
                if (httpsRunning_.load()) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                }
                continue;
            }
            std::thread([this, client]() {
                HandleHttpsClient(client);
                mbedtls_net_free(client);
                delete client;
            }).detach();
        }
    }

    void HandleHttpsClient(mbedtls_net_context *client)
    {
        timeval timeout {};
        timeout.tv_sec = 8;
        setsockopt(client->fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client->fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        mbedtls_ssl_context ssl;
        mbedtls_ssl_init(&ssl);
        std::unique_lock<std::mutex> handshakeLock(httpsHandshakeMutex_);
        if (mbedtls_ssl_setup(&ssl, &httpsConfig_) != 0) {
            mbedtls_ssl_free(&ssl);
            return;
        }
        mbedtls_ssl_set_bio(&ssl, client, mbedtls_net_send, mbedtls_net_recv, nullptr);
        int result = 0;
        while ((result = mbedtls_ssl_handshake(&ssl)) != 0) {
            if (result != MBEDTLS_ERR_SSL_WANT_READ && result != MBEDTLS_ERR_SSL_WANT_WRITE) {
                mbedtls_ssl_free(&ssl);
                return;
            }
        }
        handshakeLock.unlock();
        std::string request;
        unsigned char buffer[4096];
        size_t expectedBytes = 0;
        while (request.size() < MAX_REQUEST_BYTES) {
            result = mbedtls_ssl_read(&ssl, buffer, sizeof(buffer));
            if (result == MBEDTLS_ERR_SSL_WANT_READ || result == MBEDTLS_ERR_SSL_WANT_WRITE) {
                continue;
            }
            if (result <= 0) {
                break;
            }
            request.append(reinterpret_cast<const char *>(buffer), static_cast<size_t>(result));
            const size_t headerEnd = request.find("\r\n\r\n");
            if (headerEnd != std::string::npos) {
                if (expectedBytes == 0) {
                    expectedBytes = headerEnd + 4 + ContentLength(request.substr(0, headerEnd));
                }
                if (request.size() >= expectedBytes) {
                    break;
                }
            }
        }
        const std::string response = ProxyToLocalHttp(request);
        size_t sent = 0;
        while (sent < response.size()) {
            result = mbedtls_ssl_write(&ssl,
                reinterpret_cast<const unsigned char *>(response.data() + sent), response.size() - sent);
            if (result == MBEDTLS_ERR_SSL_WANT_READ || result == MBEDTLS_ERR_SSL_WANT_WRITE) {
                continue;
            }
            if (result <= 0) {
                break;
            }
            sent += static_cast<size_t>(result);
        }
        mbedtls_ssl_close_notify(&ssl);
        mbedtls_ssl_free(&ssl);
    }

    std::string ProxyToLocalHttp(const std::string &request)
    {
        const int proxy = socket(AF_INET, SOCK_STREAM, 0);
        if (proxy < 0) {
            return "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        }
        sockaddr_in address {};
        address.sin_family = AF_INET;
        address.sin_port = htons(port_);
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
        if (connect(proxy, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
            close(proxy);
            return "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        }
        size_t sent = 0;
        while (sent < request.size()) {
            const ssize_t count = send(proxy, request.data() + sent, request.size() - sent, 0);
            if (count <= 0) break;
            sent += static_cast<size_t>(count);
        }
        shutdown(proxy, SHUT_WR);
        std::string response;
        char buffer[4096];
        while (response.size() < MAX_REQUEST_BYTES) {
            const ssize_t count = recv(proxy, buffer, sizeof(buffer), 0);
            if (count <= 0) break;
            response.append(buffer, static_cast<size_t>(count));
        }
        close(proxy);
        return response;
    }

    void FreeHttps()
    {
        mbedtls_net_free(&httpsListen_);
        mbedtls_ssl_config_free(&httpsConfig_);
        mbedtls_x509_crt_free(&httpsCertificate_);
        mbedtls_pk_free(&httpsPrivateKey_);
        mbedtls_ctr_drbg_free(&httpsCtrDrbg_);
        mbedtls_entropy_free(&httpsEntropy_);
    }

    void HandleClient(int client)
    {
        timeval timeout { 3, 0 };
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        std::string request;
        char buffer[4096];
        size_t expectedBytes = 0;
        while (request.size() < MAX_REQUEST_BYTES) {
            const ssize_t received = recv(client, buffer, sizeof(buffer), 0);
            if (received <= 0) {
                break;
            }
            request.append(buffer, static_cast<size_t>(received));
            const size_t headerEnd = request.find("\r\n\r\n");
            if (headerEnd != std::string::npos) {
                if (expectedBytes == 0) {
                    expectedBytes = headerEnd + 4 + ContentLength(request.substr(0, headerEnd));
                }
                if (request.size() >= expectedBytes) {
                    break;
                }
            }
        }
        requestCount_.fetch_add(1);
        const size_t firstLineEnd = request.find("\r\n");
        if (firstLineEnd == std::string::npos) {
            SendJson(client, 400, "{\"ok\":false,\"message\":\"invalid request\"}");
            return;
        }
        std::istringstream firstLine(request.substr(0, firstLineEnd));
        std::string method;
        std::string target;
        std::string version;
        firstLine >> method >> target >> version;
        const size_t headerEnd = request.find("\r\n\r\n");
        const std::string body = headerEnd == std::string::npos ? "" : request.substr(headerEnd + 4);

        if (method == "OPTIONS") {
            SendJson(client, 200, "{\"ok\":true}");
            return;
        }
        if (method == "GET" && (target == "/api/health" || target == "/api/state")) {
            std::ostringstream json;
            json << "{\"ok\":true,\"service\":\"dayu-local-gateway\",\"port\":" << port_
                 << ",\"requests\":" << requestCount_.load() << "}";
            SendJson(client, 200, json.str());
            return;
        }
        if (method == "POST" && target == "/api/http/sensor") {
            cJSON *root = cJSON_ParseWithLength(body.c_str(), body.size());
            std::string deviceId;
            std::string topic;
            std::string payloadBase64;
            if (root == nullptr || !ReadJsonString(root, "deviceId", deviceId) ||
                !ReadJsonString(root, "topic", topic) || !ReadJsonString(root, "payloadBase64", payloadBase64) ||
                !IsValidDeviceId(deviceId) || !TopicMatchesDevice(topic, deviceId) || payloadBase64.empty()) {
                cJSON_Delete(root);
                SendJson(client, 400, "{\"ok\":false,\"message\":\"invalid sensor payload\"}");
                return;
            }
            const int32_t bytes = Base64DecodedBytes(payloadBase64);
            cJSON_Delete(root);
            PushEvent("http_sensor", body);
            std::ostringstream json;
            json << "{\"ok\":true,\"accepted\":true,\"deviceId\":\"" << JsonEscape(deviceId)
                 << "\",\"bytes\":" << bytes << ",\"timestamp\":" << NowMs() << "}";
            SendJson(client, 200, json.str());
            return;
        }
        if (method == "POST" && target == "/api/http/command") {
            cJSON *root = cJSON_ParseWithLength(body.c_str(), body.size());
            std::string deviceId;
            std::string topic;
            std::string payloadBase64;
            if (root == nullptr || !ReadJsonString(root, "deviceId", deviceId) ||
                !ReadJsonString(root, "topic", topic) || !ReadJsonString(root, "payloadBase64", payloadBase64) ||
                !IsValidDeviceId(deviceId) || !TopicMatchesDevice(topic, deviceId) || payloadBase64.empty()) {
                cJSON_Delete(root);
                SendJson(client, 400, "{\"ok\":false,\"message\":\"invalid command payload\"}");
                return;
            }
            const int32_t bytes = Base64DecodedBytes(payloadBase64);
            cJSON_Delete(root);
            const std::string commandId = Enqueue(deviceId, topic, payloadBase64, bytes);
            std::ostringstream json;
            json << "{\"ok\":true,\"deviceId\":\"" << JsonEscape(deviceId)
                 << "\",\"topic\":\"" << JsonEscape(topic)
                 << "\",\"commandId\":\"" << JsonEscape(commandId)
                 << "\",\"bytes\":" << bytes << ",\"timestamp\":" << NowMs() << "}";
            SendJson(client, 200, json.str());
            return;
        }
        if (method == "GET" && target.rfind("/api/http/command", 0) == 0) {
            const std::string deviceId = QueryParam(target, "deviceId");
            if (deviceId.empty()) {
                SendJson(client, 400, "{\"ok\":false,\"message\":\"invalid deviceId\"}");
                return;
            }
            SendJson(client, 200, PopCommandJson(deviceId));
            return;
        }
        SendJson(client, 404, "{\"ok\":false,\"message\":\"not found\"}");
    }

    static size_t ContentLength(const std::string &headers)
    {
        const std::string marker = "Content-Length:";
        size_t at = headers.find(marker);
        if (at == std::string::npos) {
            at = headers.find("content-length:");
        }
        if (at == std::string::npos) {
            return 0;
        }
        at += marker.size();
        while (at < headers.size() && headers[at] == ' ') {
            ++at;
        }
        return static_cast<size_t>(std::strtoul(headers.c_str() + at, nullptr, 10));
    }

    static void SendJson(int client, int status, const std::string &body)
    {
        const char *reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : "Not Found";
        std::ostringstream response;
        response << "HTTP/1.1 " << status << ' ' << reason << "\r\n"
                 << "Content-Type: application/json; charset=utf-8\r\n"
                 << "Content-Length: " << body.size() << "\r\n"
                 << "Connection: close\r\n"
                 << "Access-Control-Allow-Origin: *\r\n\r\n" << body;
        const std::string bytes = response.str();
        size_t sent = 0;
        while (sent < bytes.size()) {
            const ssize_t count = send(client, bytes.data() + sent, bytes.size() - sent, 0);
            if (count <= 0) {
                break;
            }
            sent += static_cast<size_t>(count);
        }
    }

    void PushEvent(const std::string &type, const std::string &body)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        events_.push_back({type, body, NowMs()});
        while (events_.size() > 100) {
            events_.pop_front();
        }
    }

    std::string PopCommandJson(const std::string &deviceId)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = commands_.find(deviceId);
        if (found == commands_.end() || found->second.empty()) {
            return "{\"ok\":true,\"hasCommand\":false,\"deviceId\":\"" +
                JsonEscape(deviceId) + "\"}";
        }
        while (!found->second.empty() && found->second.front().bytes >= 64 &&
            found->second.front().bytes <= 69 && NowMs() - found->second.front().timestamp > PROTOCOL_COMMAND_TTL_MS) {
            found->second.pop_front();
        }
        if (found->second.empty()) {
            return "{\"ok\":true,\"hasCommand\":false,\"deviceId\":\"" +
                JsonEscape(deviceId) + "\"}";
        }
        GatewayCommand command = std::move(found->second.front());
        found->second.pop_front();
        std::ostringstream json;
        json << "{\"ok\":true,\"hasCommand\":true,\"deviceId\":\"" << JsonEscape(deviceId)
             << "\",\"commandId\":\"" << JsonEscape(command.id)
             << "\",\"topic\":\"" << JsonEscape(command.topic)
             << "\",\"payloadBase64\":\"" << JsonEscape(command.payloadBase64)
             << "\",\"bytes\":" << command.bytes
             << ",\"timestamp\":" << command.timestamp << "}";
        return json.str();
    }

    std::atomic<bool> running_ {false};
    std::atomic<uint64_t> requestCount_ {0};
    std::atomic<uint64_t> commandSequence_ {0};
    std::atomic<bool> mqttRunning_ {false};
    std::atomic<bool> httpsRunning_ {false};
    int listenFd_ = -1;
    uint16_t port_ = 0;
    uint16_t httpsPort_ = 0;
    std::thread acceptThread_;
    std::thread httpsThread_;
    mbedtls_net_context httpsListen_ {};
    mbedtls_ssl_config httpsConfig_ {};
    mbedtls_x509_crt httpsCertificate_ {};
    mbedtls_pk_context httpsPrivateKey_ {};
    mbedtls_entropy_context httpsEntropy_ {};
    mbedtls_ctr_drbg_context httpsCtrDrbg_ {};
    std::mutex httpsRngMutex_;
    std::mutex httpsHandshakeMutex_;
    std::mutex mutex_;
    std::deque<GatewayEvent> events_;
    std::unordered_map<std::string, std::deque<GatewayCommand>> commands_;
};

napi_value MakeString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

std::string ReadString(napi_env env, napi_value value)
{
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::vector<char> buffer(length + 1, 0);
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    return std::string(buffer.data(), length);
}

napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t port = 3000;
    if (argc > 0) {
        napi_get_value_int32(env, argv[0], &port);
    }
    std::string error;
    const bool ok = port > 0 && port <= 65535 && LocalGateway::Instance().Start(static_cast<uint16_t>(port), error);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value okValue = nullptr;
    napi_get_boolean(env, ok, &okValue);
    napi_set_named_property(env, result, "ok", okValue);
    napi_set_named_property(env, result, "message", MakeString(env, ok ? "local gateway running" : error));
    napi_value portValue = nullptr;
    napi_create_int32(env, port, &portValue);
    napi_set_named_property(env, result, "port", portValue);
    return result;
}

napi_value Stop(napi_env env, napi_callback_info info)
{
    (void)info;
    LocalGateway::Instance().Stop();
    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

napi_value GetStatus(napi_env env, napi_callback_info info)
{
    (void)info;
    LocalGateway &gateway = LocalGateway::Instance();
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value running = nullptr;
    napi_get_boolean(env, gateway.IsRunning(), &running);
    napi_set_named_property(env, result, "running", running);
    napi_value mqttRunning = nullptr;
    napi_get_boolean(env, gateway.IsMqttRunning(), &mqttRunning);
    napi_set_named_property(env, result, "mqttRunning", mqttRunning);
    napi_value httpsRunning = nullptr;
    napi_get_boolean(env, gateway.IsHttpsRunning(), &httpsRunning);
    napi_set_named_property(env, result, "httpsRunning", httpsRunning);
    napi_value port = nullptr;
    napi_create_int32(env, gateway.Port(), &port);
    napi_set_named_property(env, result, "port", port);
    napi_value httpsPort = nullptr;
    napi_create_int32(env, gateway.HttpsPort(), &httpsPort);
    napi_set_named_property(env, result, "httpsPort", httpsPort);
    napi_value requests = nullptr;
    napi_create_int64(env, static_cast<int64_t>(gateway.RequestCount()), &requests);
    napi_set_named_property(env, result, "requests", requests);
    return result;
}

napi_value StartMqtt(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t port = 1883;
    int32_t tlsPort = 0;
    std::string certificate;
    std::string privateKey;
    if (argc > 0) {
        napi_get_value_int32(env, argv[0], &port);
    }
    if (argc > 1) {
        napi_get_value_int32(env, argv[1], &tlsPort);
    }
    if (argc > 2) {
        certificate = ReadString(env, argv[2]);
    }
    if (argc > 3) {
        privateKey = ReadString(env, argv[3]);
    }
    std::string error;
    const bool ok = port > 0 && port <= 65535 &&
        tlsPort >= 0 && tlsPort <= 65535 &&
        LocalGateway::Instance().StartMqtt(static_cast<uint16_t>(port), static_cast<uint16_t>(tlsPort),
            certificate, privateKey, error);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value okValue = nullptr;
    napi_get_boolean(env, ok, &okValue);
    napi_set_named_property(env, result, "ok", okValue);
    napi_set_named_property(env, result, "message", MakeString(env, ok ? "NanoMQ broker starting" : error));
    napi_value portValue = nullptr;
    napi_create_int32(env, port, &portValue);
    napi_set_named_property(env, result, "port", portValue);
    return result;
}

napi_value StartHttps(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_type_error(env, nullptr, "Expected port, certificatePem and privateKeyPem");
        return nullptr;
    }
    int32_t port = 3444;
    napi_get_value_int32(env, argv[0], &port);
    std::string error;
    const bool ok = port > 0 && port <= 65535 && LocalGateway::Instance().StartHttps(
        static_cast<uint16_t>(port), ReadString(env, argv[1]), ReadString(env, argv[2]), error);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value okValue = nullptr;
    napi_get_boolean(env, ok, &okValue);
    napi_set_named_property(env, result, "ok", okValue);
    napi_set_named_property(env, result, "message", MakeString(env, ok ? "HTTPS bridge running" : error));
    napi_value portValue = nullptr;
    napi_create_int32(env, port, &portValue);
    napi_set_named_property(env, result, "port", portValue);
    return result;
}

napi_value EnqueueCommand(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_type_error(env, nullptr, "Expected deviceId, topic, payloadBase64 and bytes");
        return nullptr;
    }
    int32_t bytes = 0;
    napi_get_value_int32(env, argv[3], &bytes);
    LocalGateway::Instance().Enqueue(ReadString(env, argv[0]), ReadString(env, argv[1]),
        ReadString(env, argv[2]), bytes);
    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

napi_value PollEvents(napi_env env, napi_callback_info info)
{
    (void)info;
    const std::vector<GatewayEvent> events = LocalGateway::Instance().DrainEvents();
    napi_value result = nullptr;
    napi_create_array_with_length(env, events.size(), &result);
    for (size_t i = 0; i < events.size(); ++i) {
        napi_value item = nullptr;
        napi_create_object(env, &item);
        napi_set_named_property(env, item, "type", MakeString(env, events[i].type));
        napi_set_named_property(env, item, "body", MakeString(env, events[i].body));
        napi_value timestamp = nullptr;
        napi_create_int64(env, events[i].timestamp, &timestamp);
        napi_set_named_property(env, item, "timestamp", timestamp);
        napi_set_element(env, result, static_cast<uint32_t>(i), item);
    }
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startMqtt", nullptr, StartMqtt, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startHttps", nullptr, StartHttps, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStatus", nullptr, GetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"enqueueCommand", nullptr, EnqueueCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pollEvents", nullptr, PollEvents, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

} // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
