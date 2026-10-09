use codex_features::MultiAgentMessageDelivery;
use codex_protocol::ThreadId;
use codex_protocol::protocol::InterAgentCommunication;

pub(crate) static PENDING_MAILBOX_MESSAGES: codex_diagnostics::Gauge =
    codex_diagnostics::Gauge::new("core.mailbox.pending");

const AGENT_COMMUNICATION_TARGET: &str = "codex_otel.agent_communication";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AgentCommunicationKind {
    Spawn,
    Message,
    Followup,
    Result,
}

impl AgentCommunicationKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Spawn => "spawn",
            Self::Message => "message",
            Self::Followup => "followup",
            Self::Result => "result",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AgentCommunicationContext {
    kind: AgentCommunicationKind,
    sender_thread_id: ThreadId,
    message_delivery: MultiAgentMessageDelivery,
}

impl AgentCommunicationContext {
    pub(crate) fn new(kind: AgentCommunicationKind, sender_thread_id: ThreadId) -> Self {
        Self {
            kind,
            sender_thread_id,
            message_delivery: MultiAgentMessageDelivery::Encrypted,
        }
    }

    pub(crate) fn with_message_delivery(
        mut self,
        message_delivery: MultiAgentMessageDelivery,
    ) -> Self {
        self.message_delivery = message_delivery;
        self
    }
}

pub(crate) fn logging_enabled() -> bool {
    tracing::enabled!(target: AGENT_COMMUNICATION_TARGET, tracing::Level::INFO)
}

pub(crate) fn emit_agent_communication_send(
    communication_id: &str,
    context: &AgentCommunicationContext,
    communication: &InterAgentCommunication,
    receiver_thread_id: ThreadId,
) {
    tracing::info!(
        target: AGENT_COMMUNICATION_TARGET,
        {
            event.name = "codex.agent_communication",
            communication_id,
            kind = context.kind.as_str(),
            state = "send",
            sender_thread_id = %context.sender_thread_id,
            receiver_thread_id = %receiver_thread_id,
            content = communication
                .encrypted_content
                .as_deref()
                .unwrap_or_else(|| match context.message_delivery {
                    MultiAgentMessageDelivery::Encrypted => "[plaintext]",
                    MultiAgentMessageDelivery::Plaintext => &communication.content,
                }),
        },
        "agent communication"
    );
}

pub(crate) fn emit_agent_communication_receive(communication_id: &str) {
    tracing::info!(
        target: AGENT_COMMUNICATION_TARGET,
        {
            event.name = "codex.agent_communication",
            communication_id,
            state = "receive",
        },
        "agent communication"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_features::MultiAgentMessageDelivery;
    use codex_protocol::AgentPath;
    use std::collections::BTreeMap;
    use std::sync::Arc;
    use std::sync::Mutex;
    use tracing::Event;
    use tracing::Subscriber;
    use tracing::field::Visit;
    use tracing_subscriber::Layer;
    use tracing_subscriber::layer::Context;
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    #[derive(Default)]
    struct FieldCollector(BTreeMap<String, String>);

    impl Visit for FieldCollector {
        fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
            self.0.insert(field.name().to_string(), value.to_string());
        }

        fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
            self.0
                .insert(field.name().to_string(), format!("{value:?}"));
        }
    }

    #[derive(Clone)]
    struct CommunicationCollector(Arc<Mutex<Vec<BTreeMap<String, String>>>>);

    impl<S: Subscriber> Layer<S> for CommunicationCollector {
        fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
            if event.metadata().target() == AGENT_COMMUNICATION_TARGET {
                let mut fields = FieldCollector::default();
                event.record(&mut fields);
                self.0.lock().unwrap().push(fields.0);
            }
        }
    }

    fn capture_send(
        context: AgentCommunicationContext,
        encrypted_content: Option<&str>,
    ) -> BTreeMap<String, String> {
        let events = Arc::new(Mutex::new(Vec::new()));
        let _guard = tracing_subscriber::registry()
            .with(CommunicationCollector(Arc::clone(&events)))
            .set_default();
        let mut communication = InterAgentCommunication::new(
            AgentPath::root(),
            AgentPath::try_from("/root/child").unwrap(),
            Vec::new(),
            "visible message".to_string(),
            false,
        );
        communication.encrypted_content = encrypted_content.map(str::to_string);
        emit_agent_communication_send(
            "communication-123",
            &context,
            &communication,
            ThreadId::from_string("00000000-0000-0000-0000-000000000002").unwrap(),
        );
        let events = events.lock().unwrap();
        assert_eq!(events.len(), 1);
        events[0].clone()
    }

    fn communication_context(kind: AgentCommunicationKind) -> AgentCommunicationContext {
        AgentCommunicationContext::new(
            kind,
            ThreadId::from_string("00000000-0000-0000-0000-000000000001").unwrap(),
        )
    }

    #[test]
    fn plaintext_delivery_logs_content_for_each_communication_kind() {
        for (kind, expected_kind) in [
            (AgentCommunicationKind::Spawn, "spawn"),
            (AgentCommunicationKind::Message, "message"),
            (AgentCommunicationKind::Followup, "followup"),
            (AgentCommunicationKind::Result, "result"),
        ] {
            let fields = capture_send(
                communication_context(kind)
                    .with_message_delivery(MultiAgentMessageDelivery::Plaintext),
                None,
            );
            assert_eq!(fields["content"], "visible message");
            assert_eq!(fields["event.name"], "codex.agent_communication");
            assert_eq!(fields["communication_id"], "communication-123");
            assert_eq!(fields["kind"], expected_kind);
            assert_eq!(fields["state"], "send");
            assert_eq!(
                fields["sender_thread_id"],
                "00000000-0000-0000-0000-000000000001"
            );
            assert_eq!(
                fields["receiver_thread_id"],
                "00000000-0000-0000-0000-000000000002"
            );
        }
    }

    #[test]
    fn encrypted_delivery_redacts_unencrypted_content() {
        let fields = capture_send(
            communication_context(AgentCommunicationKind::Message)
                .with_message_delivery(MultiAgentMessageDelivery::Encrypted),
            None,
        );
        assert_eq!(fields["content"], "[plaintext]");
    }

    #[test]
    fn default_context_redacts_unencrypted_content() {
        let fields = capture_send(communication_context(AgentCommunicationKind::Message), None);
        assert_eq!(fields["content"], "[plaintext]");
    }

    #[test]
    fn ciphertext_is_logged_under_either_delivery_policy() {
        for policy in [
            MultiAgentMessageDelivery::Encrypted,
            MultiAgentMessageDelivery::Plaintext,
        ] {
            let fields = capture_send(
                communication_context(AgentCommunicationKind::Message)
                    .with_message_delivery(policy),
                Some("ciphertext"),
            );
            assert_eq!(fields["content"], "ciphertext");
        }
    }
}
