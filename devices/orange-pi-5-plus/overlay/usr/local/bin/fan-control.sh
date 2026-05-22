#!/bin/bash
# Orange Pi 5 Plus 风扇控制脚本
# 根据 CPU 温度自动调节风扇速度

THERMAL_ZONE="/sys/class/thermal/thermal_zone0/temp"
PWM_CHIP="/sys/class/pwm/pwmchip0"
PWM_CHANNEL="0"

if [[ ! -f "${THERMAL_ZONE}" ]]; then
    echo "[ERROR] 找不到温度传感器"
    exit 1
fi

# 温度阈值 (毫摄氏度)
TEMP_LOW=55000      # 55°C
TEMP_HIGH=70000     # 70°C
TEMP_CRITICAL=85000 # 85°C

# 占空比百分比
DUTY_LOW=30
DUTY_HIGH=70
DUTY_CRITICAL=100

get_temp() {
    cat "${THERMAL_ZONE}"
}

set_fan_speed() {
    local duty=$1
    local period=100000  # 100ms period
    local duty_ns=$((period * duty / 100))

    if [[ ! -d "${PWM_CHIP}/pwm${PWM_CHANNEL}" ]]; then
        echo ${PWM_CHANNEL} > "${PWM_CHIP}/export" 2>/dev/null || true
    fi

    echo ${period} > "${PWM_CHIP}/pwm${PWM_CHANNEL}/period" 2>/dev/null || true
    echo ${duty_ns} > "${PWM_CHIP}/pwm${PWM_CHANNEL}/duty_cycle" 2>/dev/null || true
    echo 1 > "${PWM_CHIP}/pwm${PWM_CHANNEL}/enable" 2>/dev/null || true
}

# 主循环
while true; do
    temp=$(get_temp)

    if [[ ${temp} -ge ${TEMP_CRITICAL} ]]; then
        set_fan_speed ${DUTY_CRITICAL}
    elif [[ ${temp} -ge ${TEMP_HIGH} ]]; then
        set_fan_speed ${DUTY_HIGH}
    elif [[ ${temp} -ge ${TEMP_LOW} ]]; then
        set_fan_speed ${DUTY_LOW}
    else
        set_fan_speed 0
    fi

    sleep 5
done
