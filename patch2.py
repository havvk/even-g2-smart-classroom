import re

with open('mobile_gateway_ios/SmartGlassGateway/Services/G2ProtocolEncoder.swift', 'r') as f:
    content = f.read()

content = content.replace(
    'payload.append(encodeVarint(configBytes.count))',
    'payload.append(Data([UInt8(configBytes.count & 0xFF)]))'
)

with open('mobile_gateway_ios/SmartGlassGateway/Services/G2ProtocolEncoder.swift', 'w') as f:
    f.write(content)
