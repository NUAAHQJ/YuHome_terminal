import fs from '@ohos.file.fs'
import { BROKER_CA_CERT } from './MqttClient'
import { DAYU_CLIENT_CERT, DAYU_CLIENT_KEY } from './TlsClientIdentity'

export interface TlsIdentityPaths {
  caPath: string
  certPath: string
  keyPath: string
}

export async function ensureTlsCaFile(directory: string): Promise<string> {
  if (directory.length === 0) {
    throw new Error('TLS certificate directory is not configured')
  }
  const caPath = `${directory}/smart-home-ca.crt`
  await writePemFile(caPath, BROKER_CA_CERT)
  return caPath
}

async function writePemFile(filePath: string, content: string): Promise<void> {
  const file = await fs.open(filePath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
  try {
    await fs.write(file.fd, content)
  } finally {
    fs.closeSync(file)
  }
}

export async function ensureTlsIdentityFiles(directory: string): Promise<TlsIdentityPaths> {
  if (directory.length === 0) {
    throw new Error('TLS certificate directory is not configured')
  }
  const caPath = await ensureTlsCaFile(directory)
  const paths: TlsIdentityPaths = {
    caPath,
    certPath: `${directory}/dayu-client.crt`,
    keyPath: `${directory}/dayu-client.key`
  }
  await writePemFile(paths.certPath, DAYU_CLIENT_CERT)
  await writePemFile(paths.keyPath, DAYU_CLIENT_KEY)
  return paths
}
