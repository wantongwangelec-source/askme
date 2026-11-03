#!/usr/bin/env python3
"""Local OpenAI-compatible streaming mock for smoke tests and UI work. Never contacts the network.

    python3 scripts/mock-llm.py 8765
    ASKME_SMOKE_ENDPOINT=http://127.0.0.1:8765/v1/chat/completions dist/Askme.app/Contents/MacOS/Askme --smoke-test
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CARD = (
    "【概念】Transformer（变换器架构）\n"
    "【一句话】一种只靠注意力机制、能并行处理整段序列的神经网络架构。\n"
    "【在这里】原文说它\"取代了 RNN\"，指它不再逐字循环计算，训练快得多。\n"
    "【类比】像把逐行执行的脚本改成并发请求：每个词同时去看其他所有词；不同的是它要为此付出平方级的计算量。\n"
    "【要点】\n- 自注意力让每个词按相关性参考其他词\n- 位置编码补上顺序信息\n- 多层堆叠逐步抽象语义\n"
    "【例子】翻译\"它很重\"时，\"它\"会把注意力集中到前文的\"箱子\"上。\n"
    "【前置】Attention｜Embedding\n"
    "【相关】RNN｜BERT\n"
    "【把握】高\n"
)
PRIMER = (
    "【主旨】这页讲大模型推理时如何用缓存节省计算。\n"
    "【前置】\n1. Token：模型处理文字的最小单位\n2. Attention（注意力）：让每个词参考其他词\n"
    "3. KV Cache（键值缓存）：复用已经算过的中间结果\n"
    "【难点】为什么缓存会随长度线性增长。\n"
)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        messages = body.get("messages", [])
        system = messages[0].get("content", "") if messages else ""
        sys.stderr.write(f"mock-llm: model={body.get('model')} stream={body.get('stream')} messages={len(messages)}\n")
        if not body.get("stream"):
            self.send_error(400, "expected stream: true")
            return
        if len(messages) > 2:
            answer = "这是一个追问的回答：\n\n- 第一点\n- 第二点\n"
        elif "知识预装载" in system:
            answer = PRIMER
        else:
            answer = CARD
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(b": warming up\n\n")
        time.sleep(0.05)
        for start in range(0, len(answer), 6):
            chunk = {"choices": [{"delta": {"content": answer[start:start + 6]}}]}
            self.wfile.write(f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.015)
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
