export function pageBg(isDark: boolean, hasAlarm: boolean): string {
  if (hasAlarm) {
    return isDark ? '#2B0D12' : '#F9E8E9'
  }
  return isDark ? '#07111A' : '#DDF5EC'
}

export function sideBg(isDark: boolean, hasAlarm: boolean): string {
  if (hasAlarm) {
    return isDark ? '#351016' : '#F8E5E6'
  }
  return isDark ? '#07111A' : '#DDF5EC'
}

export function cardBg(isDark: boolean): string {
  return isDark ? '#E6101926' : '#E0FFFFFF'
}

export function softPanelBg(isDark: boolean, hasAlarm: boolean): string {
  if (hasAlarm) {
    return isDark ? '#3B2228' : '#F9E9EA'
  }
  return isDark ? '#19273A' : '#E5F7F4'
}

export function textColor(isDark: boolean): string {
  return isDark ? '#EEF6FF' : '#111716'
}

export function pageTitleColor(isDark: boolean, hasAlarm: boolean): string {
  if (hasAlarm) {
    return isDark ? '#F1A8AF' : '#963E47'
  }
  return isDark ? '#70E6D2' : '#106C61'
}

export function pageTitleGlowColor(isDark: boolean, hasAlarm: boolean): string {
  if (hasAlarm) {
    return isDark ? '#F18E9866' : '#CE6D7742'
  }
  return isDark ? '#5EF2D866' : '#27C7AA42'
}

export function subTextColor(isDark: boolean, hasAlarm: boolean): string {
  if (hasAlarm) {
    return isDark ? '#D0A7AC' : '#785D61'
  }
  return isDark ? '#95A7BB' : '#5D7472'
}

export function hairlineColor(isDark: boolean, hasAlarm: boolean): string {
  if (hasAlarm) {
    return isDark ? '#E48A9438' : '#E1B8BC'
  }
  return isDark ? '#7EB3FF29' : '#A9D2CA'
}

export function accentBlue(isDark: boolean, hasAlarm: boolean): string {
  if (hasAlarm) {
    return isDark ? '#E07B84' : '#CC6670'
  }
  return isDark ? '#5AA9FF' : '#2589FF'
}

export function accentOrange(hasAlarm: boolean): string {
  return hasAlarm ? '#E49A58' : '#5AA9FF'
}

export function accentGreen(hasAlarm: boolean): string {
  return hasAlarm ? '#C45D67' : '#25A395'
}

export function accentGlowColor(hasAlarm: boolean): string {
  return hasAlarm ? '#C45D6742' : '#28C9AA42'
}

export function activeDeviceBorderColor(hasAlarm: boolean): string {
  return hasAlarm ? '#C45D6788' : '#25A39588'
}

export function controlTrackColor(isDark: boolean, hasAlarm: boolean): string {
  if (hasAlarm) {
    return isDark ? '#5A353A' : '#EAD2D5'
  }
  return isDark ? '#3A3F44' : '#DCE7EF'
}

export function alarmCardBg(isDark: boolean): string {
  return isDark ? '#4A2026' : '#F7DCDD'
}

export function alarmTextColor(isDark: boolean): string {
  return isDark ? '#FFDDE0' : '#762D36'
}

export function alarmSubTextColor(isDark: boolean): string {
  return isDark ? '#EAB7BC' : '#92545B'
}

export function warningRed(): string {
  return '#D97662'
}

export function alertColor(alertLevel: number): string {
  if (alertLevel === 1) {
    return '#4FA8F6'
  }
  if (alertLevel === 2) {
    return '#D97662'
  }
  if (alertLevel === 3) {
    return '#A94442'
  }
  return '#38C98D'
}
