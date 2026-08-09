#!/usr/bin/env bash
# =============================================================================
# SmartGlassWatch Apple Watch App 一键编译、部署与启动脚本 (Release 模式)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../mobile_gateway_ios" && pwd)"

echo "🚀 [1/3] 正在查询已连接的 Apple Watch 设备..."
WATCH_DEVICE_LINE=$(xcodebuild -project "${PROJECT_DIR}/SmartGlassGateway.xcodeproj" -scheme SmartGlassWatch -showdestinations | grep "platform:watchOS," | grep -v "placeholder" | grep -v "Simulator" | head -n 1 || true)

if [ -z "${WATCH_DEVICE_LINE}" ]; then
    echo "❌ 未检测到已连接的真机 Apple Watch 设备！请确保 Apple Watch 已与 iPhone 配对并已开启开发者模式。"
    exit 1
fi

WATCH_DEVICE_ID=$(echo "${WATCH_DEVICE_LINE}" | sed -n 's/.*id:\([^,]*\).*/\1/p' | tr -d ' ')
WATCH_DEVICE_NAME=$(echo "${WATCH_DEVICE_LINE}" | sed -n 's/.*name:\([^}]*\).*/\1/p')

echo "⌚️ 检测到 Apple Watch 设备: ${WATCH_DEVICE_NAME} (ID: ${WATCH_DEVICE_ID})"

echo "🔨 [2/3] 正在编译 SmartGlassWatch App (Release 模式)..."
xcodebuild -project "${PROJECT_DIR}/SmartGlassGateway.xcodeproj" \
           -scheme SmartGlassWatch \
           -configuration Release \
           -destination "id=${WATCH_DEVICE_ID}" \
           -derivedDataPath "${PROJECT_DIR}/build" \
           build

echo "📲 [3/3] 正在部署 App 至 Apple Watch (${WATCH_DEVICE_NAME})..."
# 寻找编译产物路径 (单独立项或嵌套 App)
WATCH_APP_PATH="${PROJECT_DIR}/build/Build/Products/Release-watchos/SmartGlassWatch.app"

if [ ! -d "${WATCH_APP_PATH}" ]; then
    WATCH_APP_PATH="${PROJECT_DIR}/build/Build/Products/Release-iphoneos/SmartGlassGateway.app/Watch/SmartGlassWatch.app"
fi

xcrun devicectl device install app --device "${WATCH_DEVICE_ID}" "${WATCH_APP_PATH}"

echo "⚡️ 尝试拉起 Apple Watch 应用..."
xcrun devicectl device process launch --device "${WATCH_DEVICE_ID}" edu.ncu.smartglass.gateway.watchkit || echo "⚠️ 请解锁 Apple Watch 屏幕，点击 SmartGlassWatch 图标手动启动。"

echo "✅ Apple Watch App 部署完成！"
