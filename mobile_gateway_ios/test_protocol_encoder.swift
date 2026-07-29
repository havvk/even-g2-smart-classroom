import Foundation

@main
struct TestApp {
    static func main() {
        let sampleText = """
        各位领导、各位老师，大家上午好！欢迎参加 2026 年人机协同 Smart Classroom 集体备课会。
        首先我们来看执行摘要的第一部分，关于课程痛点与定位。为了响应专业+AI 的培养大势，采用了每周 2+2 理实一体课。
        因此本课程重新确立了 HOTL (Human-On-The-Loop) 人在回路上的核心定位，引入人机环路控制理论。
        接下来是执行摘要的第二部分，介绍教学策略与资源部署。策略上基于 A/S/P 标记框架实施渐进式脚手架拆除。
        在资源建设上，建议学校拨出专项算力资金在本地私有部署 Python 和 LLM 模型，消除开销壁垒。
        """

        let pages = G2ProtocolEncoder.formatTextToPages(sampleText, maxLineWidth: 56, linesPerPage: 10, targetPageCount: 14)
        print("Formatted pages count: \(pages.count)")

        var seq: UInt8 = 0x08
        let msgId = 0x16

        let pkts = G2ProtocolEncoder.buildContentPagePackets(seq: &seq, msgId: msgId, pageNum: 0, text: pages[0])
        print("Page 0 packets count: \(pkts.count)")
        for (idx, pkt) in pkts.enumerated() {
            print("  Sub-pkt \(idx + 1): \(pkt.count) bytes, hex: \(pkt.map { String(format: "%02x", $0) }.joined())")
        }
    }
}
