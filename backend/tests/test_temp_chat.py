from app.api import temp_chat


def test_find_matching_user_seq_prefers_exact_sent_message() -> None:
    sent_message = "BOARD CHAT (temporary)\nBoard: Demo\nFrom: User\n\nHello"
    messages = [
        {
            "role": "user",
            "content": "unrelated earlier message",
            "__openclaw": {"seq": 101},
        },
        {
            "role": "user",
            "content": sent_message,
            "__openclaw": {"seq": 103},
        },
        {
            "role": "assistant",
            "content": [{"type": "text", "text": "TEMP_CHAT_OK"}],
            "__openclaw": {"seq": 104},
        },
    ]

    assert (
        temp_chat._find_matching_user_seq(
            messages,
            after_seq=100,
            expected_message=sent_message,
        )
        == 103
    )


def test_find_assistant_reply_after_seq_uses_resolved_anchor() -> None:
    messages = [
        {
            "role": "assistant",
            "content": [{"type": "text", "text": "stale reply"}],
            "__openclaw": {"seq": 102},
        },
        {
            "role": "user",
            "content": "our sent message",
            "__openclaw": {"seq": 103},
        },
        {
            "role": "assistant",
            "content": [{"type": "text", "text": "real reply"}],
            "__openclaw": {"seq": 104},
        },
    ]

    assert (
        temp_chat._find_assistant_reply_after_seq(
            messages,
            after_seq=103,
        )
        == "real reply"
    )


def test_find_assistant_reply_after_seq_skips_empty_error_messages() -> None:
    messages = [
        {
            "role": "user",
            "content": "our sent message",
            "__openclaw": {"seq": 103},
        },
        {
            "role": "assistant",
            "content": [],
            "__openclaw": {"seq": 104},
        },
        {
            "role": "assistant",
            "content": [{"type": "text", "text": "TEMP_CHAT_OK"}],
            "__openclaw": {"seq": 105},
        },
    ]

    assert (
        temp_chat._find_assistant_reply_after_seq(
            messages,
            after_seq=103,
        )
        == "TEMP_CHAT_OK"
    )
