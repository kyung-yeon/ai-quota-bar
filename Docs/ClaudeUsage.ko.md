# Claude 초기화권

Claude는 Fable 초기화권 등 보관해 두었다가 사용할 수 있는 한도 초기화권을 지급할 수 있습니다. 유료 사용 크레딧이나 5시간·주간 한도의 자동 초기화 일정과는 별개입니다. Anthropic의 [초기화권 안내](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset)와 [Fable 5.2 출시 혜택](https://support.claude.com/en/articles/17506494-claude-fable-5-2-launch-offers)을 참고하세요.

AiQuotaBar는 기존 Claude Code OAuth 자격증명으로 `GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1`을 조회합니다. 같은 응답의 사용량 창을 유지하며 `skip_spend`나 `at_wall`은 보내지 않습니다. 이 쿼리와 CLI 형식 User-Agent는 관찰된 내부 동작으로, 안정적인 공개 API 계약은 아닙니다. [최초 OAuth 관찰](https://github.com/steipete/CodexBar/issues/3895)과 [독립 구현](https://github.com/steipete/CodexBar/pull/4232)이 근거이며, 설치된 Claude Code 2.1.322 바이너리에서도 조회 쿼리·`resets_left`·`claude-cli/` User-Agent 형식을 확인했습니다.

앱은 제한 시간 내에 CLI의 `--version`을 읽고 `claude-cli/<version> (external, cli)`로 선택적 초기화권 정보를 요청합니다. 버전을 읽지 못하면 일반 사용량 요청을 사용합니다. HTTP 400 또는 일반 403이면 초기화권 쿼리를 빼고 기존 AiQuotaBar 요청 형식으로 한 번만 재시도합니다. 인증·권한 오류, 요청 제한, 서버 오류는 기존 처리를 유지합니다. 별도 토큰·브라우저 쿠키·계정 조회·로그인 절차는 추가하지 않습니다.

`cedar_ember.eligible: true`와 읽을 수 있는 `grants` 배열이 있어야 합니다. 항목 개수가 아니라 각 항목의 `resets_left`를 합산하며, 일시 중지·시작 전·소진·만료 항목은 제외합니다. `usable_now`는 잔여량이 아니라 지금 사용할 수 있는지를 뜻하므로 보유량 집계에 사용하지 않습니다. 유효기간은 `ends_at`에서 읽고, 날짜가 없으면 제공되지 않았다고 표시합니다. 확인된 유효기간이 지나면 다음 조회 전에도 개수에서 제외합니다. 한 항목에 여러 장이 있으면 개수와 공통 유효기간을 함께 표시합니다.

항목 누락·조회 자격 미충족·형식 오류는 0장이 아닌 미확인 상태이며, 정상 사용량 창은 그대로 표시합니다. 카드의 **초기화권 · API 응답에 정보 없음**은 계정에 초기화권이 없다는 뜻이 아닙니다. 정상적으로 비어 있는 목록만 0장으로 표시합니다. `extra_usage`, 주간 초기화 시각, 구독 기간으로 초기화권을 추정하지 않습니다.

조회·표시만 구현하며 초기화권을 사용하는 POST는 없습니다. 실제 사용에 필요한 grant ID와 서버 설명은 보관하지 않고, 응답·자격증명을 로그에 남기지 않습니다. 리다이렉트를 거부하며 임시 세션의 URL 캐시도 비활성화합니다. 이번 변경은 로컬 컴파일로 확인했으며, 특정 계정의 자격을 검증하기 위한 인증된 계정 조회나 초기화권 사용은 실행하지 않았습니다.
