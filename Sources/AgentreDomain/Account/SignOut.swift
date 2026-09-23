import Foundation

/// 退出登录的唯一执行者：主动退出、切换服务器、撤销本机与刷新被拒都走这里。
///
/// 先清本地会话库、再清钥匙串里的令牌并回到登录屏：中途被杀时宁可留在登录态而库已空，
/// 也不能已回到登录屏而上一个账号的会话还躺在库里。库清不掉时再试一次；仍清不掉，
/// 令牌照样清掉——不能因为库出错把用户留在一个半登出的状态里。
///
/// 清库之前先跑 `beforeClearing`（装配层在这里拆掉登录态那一套：中继连接、跟随、在途的调用）：
/// 否则一个在途的派单或跟随会在库清空之后把上一个账号的会话写回来。
@MainActor
public final class SignOut {
    private let session: AppSession
    private let store: any ConversationStore
    public var beforeClearing: (@MainActor () async -> Void)?

    public init(session: AppSession, store: any ConversationStore) {
        self.session = session
        self.store = store
    }

    public func run() async {
        await beforeClearing?()
        if (try? await store.removeAll()) == nil {
            try? await store.removeAll()
        }
        session.signOut()
    }
}
