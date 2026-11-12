# Claude 키체인 권한 창

AiQuotaBar는 현재 macOS 사용자 이름으로 Claude Code의 기존 일반 암호 항목인 `Claude Code-credentials`를 읽습니다. 별도 설정 디렉터리가 있으면 해당 디렉터리용 서비스 이름을 사용하며 그 항목의 데이터만 요청합니다. 환경 변수 토큰과 Claude Code의 기존 `.credentials.json` 대체 경로는 그대로 유지합니다. 다른 저장소로 인증 정보를 복사하거나 키체인 항목·접근 목록을 수정하지 않습니다.

## 권한 창이 반복될 수 있었던 이유

앱 시작·5분마다의 갱신·잠자기 해제·수동 새로고침에서 인증 정보를 읽습니다. 이 경로들은 이미 `allowKeychainPrompt: false`였고, **Claude Code 키체인 접근 허용…**만 true였습니다. 문제는 이 정책을 적용하는 방식이었습니다. `LAContext.interactionNotAllowed`만 설정했지만, Claude의 기존 로그인 키체인 항목은 앱별 접근 목록(legacy ACL)을 사용하므로 이 설정만으로 해당 권한 창을 막을 수 없었습니다. Apple Security SDK의 `SecItem.h`는 저장소의 차이를 설명하며, 기존 키체인 구현은 `kSecUseAuthenticationContext`를 ACL 대화상자 정책으로 처리하지 않습니다.

이와 별개로 권한 자체가 다시 필요할 수도 있습니다. Apple의 [접근 목록 설명](https://developer.apple.com/documentation/security/access-control-lists)에 따르면 **허용**은 접근을 허용하고, **항상 허용**은 해당 앱을 항목의 신뢰 목록에 추가합니다. 로컬 AiQuotaBar는 임시 서명하며, 설치된 앱의 서명 요구사항을 읽기 전용으로 확인한 결과 바이너리의 `cdhash`에 연결되어 있었습니다. 따라서 재빌드한 앱은 다른 신원으로 인식될 수 있습니다. 인증 항목이나 접근 목록 변경도 기존 허용에 영향을 줄 수 있습니다. 이번 조사에서는 실제 인증 항목이나 ACL을 읽지 않았으므로 개별 권한이 사라진 원인까지 확정하지는 않습니다.

## 변경한 동작

앱의 모든 키체인 읽기에 같은 잠금을 적용합니다. 자동 조회에서는 기존 상호작용 상태를 저장하고 `SecKeychainSetUserInteractionAllowed(false)`로 창을 막은 뒤, 기존과 같은 `SecItemCopyMatching`을 호출하고 이전 상태를 복원합니다. 기존 `LAContext.interactionNotAllowed`도 유지합니다. 상태를 읽거나 창을 차단하는 데 실패하면 보호된 키체인 읽기를 실행하지 않고 기존 대체 파일·오류 처리를 따릅니다.

이 설정은 프로세스 전체에 적용되므로 명시적인 **접근 허용** 경로도 같은 잠금을 사용하며, 이미 차단된 프로세스 정책을 강제로 켜지 않습니다. 자동 조회 실패 후 권한 창을 허용하며 재시도하지 않습니다. 사용자가 명시적인 요청을 거부하거나 취소하면 기존 대체 파일을 읽을 수 있는 경우를 제외하고 **키체인 접근 필요**로 돌아갑니다. 이후 자동 조회도 창을 띄우지 않습니다.

기존 키체인 상호작용 API는 사용 중단 예정이지만 로그인 키체인 대화상자를 제어하는 해당 저장소의 방식입니다. 읽기 구간에만 제한하며, 키체인 잠금 해제·권한 부여·ACL 변경·인증 우회를 하지 않습니다. 인증된 `LAContext` 재사용으로 기존 앱 ACL 문제를 해결할 수 없으므로 문맥이나 토큰 캐시도 추가하지 않습니다. Apple의 [상호작용 API](https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:))와 [Security 구현](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_keychain/lib/SecKeychain.cpp)을 참고하세요.

이번 변경은 컴파일과 소스 검토로 확인합니다. 실제 인증 정보 읽기·권한 창 실험·접근 권한 변경·로컬 설치는 하지 않았습니다. 이미 떠 있는 시스템 대화상자나 Claude Code 등 다른 앱이 띄운 창은 이 앱의 조회 정책으로 제어하지 않습니다.
