import Foundation

@main
struct TestApp {
    static func main() {
        let testText = """
        各位领导、各位老师，大家上午好！欢迎参加 2026 年人机协同 Smart Classroom 集体备课会。
        首先我们来看执行摘要的第一部分，关于课程痛点与定位。为了响应专业+AI 的培养大势，采用了每周 2+2 理实一体课。
        因此本课程重新确立了 HOTL (Human-On-The-Loop) 人在回路上的核心定位，引入人机环路控制理论。
        接下来是执行摘要的第二部分，介绍教学策略与资源部署。策略上基于 A/S/P 标记框架实施渐进式脚手架拆除。
        在资源建设上，建议学校拨出专项算力资金在本地私有部署 Python 和 LLM 模型，消除开销壁垒。
        第二部分是教学方法与策略，讲解每周 2+2 理实一体设置；第三部分是考核改革，重点介绍限时测试。
        第四部分是资源标准化建设。接下来我们进入第一部分：成果导向的逻辑出发，阐述课程目标定位。
        在深入第一章细节前，我们先来看第一章的全局逻辑链图。这页概念图体现了基于 OBE 反向推导的全貌。
        为此我们引入了人机协同新范式，明确人类主导问题域与审计，AI 托管求解域。推导出最下层 OBE 目标。
        这一部分的组织逻辑是层层递进的，极大地降低了编程学习门槛，帮助学生快速获得掌控感与成就感。
        """

        let pages = G2ProtocolEncoder.formatTextToPages(testText, maxLineWidth: 56, linesPerPage: 10, targetPageCount: 14)
        print("Formatted pages count: \(pages.count)")

        var seq: UInt8 = 0x08
        var msgId = 0x16

        for (i, pageText) in pages.enumerated() {
            let pkts = G2ProtocolEncoder.buildContentPagePackets(seq: &seq, msgId: msgId, pageNum: i, text: pageText)
            let totalBytes = pkts.reduce(0) { $0 + $1.count }
            print("Page \(i): \(pkts.count) pkts, \(totalBytes) bytes")
            for (j, pkt) in pkts.enumerated() {
                print("  pkt \(j+1): len=\(pkt.count), hex: \(pkt.prefix(16).map { String(format: "%02x", $0) }.joined())")
            }
            msgId += 1
        }
    }
}
