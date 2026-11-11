# Transport and native-preview release pass

Reviewed #54 and #56 against current `main` (`c043007`), repository ownership
rules and the passing combined physical test. The scope is experimental native
previews and manual LAN/Direct selection, before terminal MCP integration.

## Findings and corrections

- Capture callbacks inherited their initial catalog request's AsyncLocalStorage
  context, producing misleading route attribution. Provider startup now explicitly
  leaves request context. Its media summaries are neutral; bounded bridge-open and
  bridge-close events carry the actual accepting route and a connection ID using
  the existing injected logger. No viewer registry, additional sink or media
  protocol change. LAN/peer-ingress tests verify request isolation and correlation.
- The launcher now labels URL rows **Web frontends**, and their unavailable message
  explicitly distinguishes them from Mac-window streams. Web capability gating
  and its shared Swift/TypeScript fixture remain in sync.
- Native video uses the same 18-point continuous rounded clipping as existing web
  previews, after its opaque background and before geometry/ornaments. This removes
  square exterior corners without changing encoded pixels or source sizing. It is
  a consistent app treatment, not a claim to infer arbitrary source-window masks.

No additional merge-blocking finding was identified in the reviewed transport,
trust/admission, lifecycle, bounded capture/encode/receive and restoration paths.
Checks include route retirement and late replies, real PTY/WebKit input and EOF
recovery, shared binary media through LAN/TLS, source/provider failure, archived
replacement scenes and real headset evidence. Tests supplement source review.

## Simplification and remaining qualification

Keep the existing boundaries: one accepted companion route, one WindowGateway,
one durable Mac layout store, process ownership in SessionManager and one injected
logging runtime. MCP should adapt these operations rather than invent a parallel
window/session manager. No broader abstraction is needed for this cleanup.

The physical gate passed before these cosmetic/logging edits. Exact rounded-corner
appearance and new wording are not separately wearer-qualified. Travel without an
access point, sleep/wake, capacity/thermals, production permission repair and
integrated locked/source-loss UX remain explicitly outside that gate. The feature
stays opt-in. There are no unresolved design questions blocking the experimental
merge; compositor masks and measured display latency remain later UX work.

The earlier #54 CI failure was EPIPE during session creation in an integration
test. The current base's complete 62-test local run and fresh CI test step pass;
no speculative session-lifetime patch was added. The preview branch has 65 tests
after upstream removed redundant synthetic tests (#53), down from the prior 71.
The initial cleanup run caught an outdated warning-text fixture; updating that
shared fixture restored the full pass.
