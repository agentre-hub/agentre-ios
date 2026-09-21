import AgentreDomain
import Testing

/// 合流：本地库、向前补的历史与实时帧按 seq 合成一条，重复的帧号只留一份。
@Suite("帧合流")
struct TimelineTests {
    func texts(_ timeline: TranscriptTimeline) -> [String] {
        timeline.entries.map { entry in
            switch entry.event {
            case .userMessage(let text): text
            case .textDelta(let text): "Δ\(text)"
            case .turnDone: "done"
            default: "?"
            }
        }
    }

    @Test("乱序到达的带号帧按 seq 排好；同号的第二份被丢弃")
    func ordersBySeqAndDedupes() {
        var timeline = TranscriptTimeline()
        let inserted = [
            timeline.insert(seq: 3, event: .userMessage("c")),
            timeline.insert(seq: 1, event: .userMessage("a")),
            timeline.insert(seq: 2, event: .userMessage("b")),
            timeline.insert(seq: 2, event: .userMessage("b-again")),
        ]
        #expect(inserted == [true, true, true, false])
        #expect(texts(timeline) == ["a", "b", "c"])
        #expect(timeline.oldestSeq == 1)
        #expect(timeline.latestSeq == 3)
        #expect(timeline.entries.map(\.anchor) == ["s1", "s2", "s3"])
    }

    @Test("不带号的实时帧（轮次边界）排在它到达时已知的最大帧号之后；之后补进来的更早帧排在它前面")
    func unnumberedFramesStayWhereTheyArrived() {
        var timeline = TranscriptTimeline()
        timeline.insert(seq: 5, event: .userMessage("e"))
        timeline.insert(seq: nil, event: .turnDone(TurnDone()))
        timeline.insert(seq: 4, event: .userMessage("d"))
        timeline.insert(seq: 6, event: .userMessage("f"))
        #expect(texts(timeline) == ["d", "e", "done", "f"])
    }

    @Test("预览帧是过场：留在末尾，下一条持久帧一到就被它取代")
    func previewsAreTransient() {
        var timeline = TranscriptTimeline()
        timeline.insert(seq: 1, event: .userMessage("a"))
        timeline.insert(seq: nil, event: .textDelta("Hel"), preview: true)
        timeline.insert(seq: nil, event: .textDelta("lo"), preview: true)
        #expect(texts(timeline) == ["a", "ΔHel", "Δlo"])
        timeline.insert(seq: 2, event: .textDelta("Hello"))
        #expect(texts(timeline) == ["a", "ΔHello"])
    }

    @Test("向前补进来的更早帧不取代预览尾巴：翻到顶时回复还在流，已流出的字不被抹掉")
    func backfillKeepsPreviews() {
        var timeline = TranscriptTimeline()
        timeline.insert(seq: 10, event: .userMessage("j"))
        timeline.insert(seq: nil, event: .textDelta("Hel"), preview: true)
        timeline.insert(seq: 9, event: .userMessage("i"))
        #expect(texts(timeline) == ["i", "j", "ΔHel"])
        timeline.insert(seq: 11, event: .textDelta("Hello"))
        #expect(texts(timeline) == ["i", "j", "ΔHello"])
    }
}

/// 自动跟随：上滚即停，回到最新时给出其间新增了多少。
@Suite("自动跟随")
struct FollowTests {
    @Test("默认跟随；上滚后停止跟随，新增按条计数；回到最新清零并恢复跟随")
    func follow() {
        var follow = TranscriptFollow()
        #expect(follow.isFollowing)
        follow.appended(3)
        #expect(follow.unseen == 0)
        follow.userScrolledAway()
        #expect(!follow.isFollowing)
        follow.appended(2)
        follow.appended(1)
        #expect(follow.unseen == 3)
        follow.jumpToLatest()
        #expect(follow.isFollowing)
        #expect(follow.unseen == 0)
    }

    @Test("用户自己滚回底部也恢复跟随")
    func reachingBottomResumes() {
        var follow = TranscriptFollow()
        follow.userScrolledAway()
        follow.appended(4)
        follow.reachedBottom()
        #expect(follow.isFollowing)
        #expect(follow.unseen == 0)
    }
}
