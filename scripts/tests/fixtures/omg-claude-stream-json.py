#!/usr/bin/python3
"""Deterministic wire fixture only. Never launches Claude or any tools."""
import json
import os
import sys

session = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith(("--session-id=", "--resume=")))
mode = os.environ["OMG_CLAUDE_TEST_MODE"]
capture = os.environ["OMG_CLAUDE_TEST_CAPTURE"]
turn = 0

def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
    sys.stdout.flush()

def stream_event(value):
    emit({"type": "stream_event", "event": value, "session_id": session, "parent_tool_use_id": None})

def result(error=False):
    emit({"type": "result", "session_id": session, "subtype": "error_during_execution" if error else "success", "is_error": error, "errors": ["fixture interrupted"] if error else []})

def text():
    mid = "assistant-" + str(turn)
    stream_event({"type": "message_start", "message": {"id": mid}})
    stream_event({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
    stream_event({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello 🌱"}})
    emit({"type": "assistant", "session_id": session, "message": {"id": mid, "content": [{"type": "text", "text": "Hello 🌱"}]}})
    stream_event({"type": "message_stop"})

for line in sys.stdin:
    request = json.loads(line)
    with open(capture, "a", encoding="utf-8") as file:
        file.write(json.dumps(request) + "\n")
    if request["type"] == "control_request":
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": request["request_id"], "response": {}}})
        if request["request"]["subtype"] == "interrupt":
            result(error=True)
    elif request["type"] == "user":
        turn += 1
        if mode == "permissions":
            emit({"type": "control_request", "request_id": "approve-1", "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {"file_path": "/fixture/file", "content": "fixture only"}, "permission_suggestions": [{"type": "setMode", "mode": "bypassPermissions"}]}})
        else:
            text()
            if mode != "interrupt": result()
    elif request["type"] == "control_response":
        response = request["response"]
        if response["request_id"] == "approve-1":
            emit({"type": "control_request", "request_id": "question-2", "request": {"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": {"questions": [{"question": "Choose colors", "multiSelect": True, "options": [{"label": "Blue", "description": "one"}, {"label": "Green", "description": "two"}]}]}}})
        else:
            text()
            result()
