#!/usr/bin/env bash
# =============================================================================
# SmartGlassGateway iOS App 一键编译、部署与启动脚本
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../mobile_gateway_ios" && pwd)"

echo "🚀 [1/3] 正在查询已连接的 iPhone 设备..."
DEVICE_LINE=$(xcodebuild -project "${PROJECT_DIR}/SmartGlassGateway.xcodeproj" -scheme SmartGlassGateway -showdestinations | grep "platform:iOS," | grep -v "placeholder" | grep -v "Simulator" | head -n 1 || true)

if [ -z "${DEVICE_LINE}" ]; then
    echo "❌ 未检测到已连接的真机 iOS 设备！请确保 iPhone 已通过 USB 连接并解锁。"
    exit 1
fi

DEVICE_ID=$(echo "${DEVICE_LINE}" | sed -n 's/.*id:\([^,]*\).*/\1/p' | tr -d ' ')
DEVICE_NAME=$(echo "${DEVICE_LINE}" | sed -n 's/.*name:\([^}]*\).*/\1/p')

echo "📱 检测到设备: ${DEVICE_NAME} (ID: ${DEVICE_ID})"

echo "🔨 [2/3] 正在编译 SmartGlassGateway App..."
xcodebuild -project "${PROJECT_DIR}/SmartGlassGateway.xcodeproj" \
           -scheme SmartGlassGateway \
           -destination "id=${DEVICE_ID}" \
           -derivedDataPath "${PROJECT_DIR}/build" \
           build

echo "📲 [3/3] 正在部署 App 至 iPhone (${DEVICE_NAME})..."
xcrun devicectl device install app --device "${DEVICE_ID}" "${PROJECT_DIR}/build/Build/Products/Debug-iphoneos/SmartGlassGateway.app"

echo "⚡️ 尝试拉起应用..."
xcrun devicectl device process launch --device "${DEVICE_ID}" edu.ncu.smartglass.SmartGlassGateway || echo "⚠️ 如果手机处于锁屏状态，请解锁手机屏幕后手动点击 SmartGlassGateway 图标启动。"

echo "✅ 部署完成！"
