// Uso: node agente.mjs <slug> "<mensagem começando com @agent>"
// Dispara o agente do AnythingLLM e acompanha o WebSocket até a resposta final.
const [slug, mensagem] = process.argv.slice(2);
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) AnythingLLM/1.16.1 Chrome/138.0.0.0 Electron/37.2.0 Safari/537.36";
const B = "http://127.0.0.1:3001/api";
const t0 = Date.now();
const seg = () => ((Date.now() - t0) / 1000).toFixed(1) + "s";

const res = await fetch(`${B}/workspace/${slug}/stream-chat`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "User-Agent": UA },
  body: JSON.stringify({ message: mensagem, attachments: [] }),
});
const sse = await res.text();
const init = sse.split(/\r?\n/).filter((l) => l.startsWith("data:")).map((l) => JSON.parse(l.slice(5))).find((j) => j.websocketUUID);
if (!init) { console.log("sem websocketUUID. SSE:", sse.slice(0, 400)); process.exit(1); }
console.log(`[${seg()}] sessão do agente: ${init.websocketUUID}`);

const ws = new WebSocket(`ws://127.0.0.1:3001/api/agent-invocation/${init.websocketUUID}`, { headers: { "User-Agent": UA } });
let texto = "";
const ferramentas = [];
const fim = setTimeout(() => { console.log(`[${seg()}] tempo esgotado`); ws.close(); }, 240000);
ws.onerror = (e) => console.log("erro ws:", e.message || e.type);
ws.onmessage = (ev) => {
  let m; try { m = JSON.parse(ev.data); } catch { return; }
  const conteudo = typeof m.content === "string" ? m.content : JSON.stringify(m.content ?? m);
  if (m.type === "toolCallInvocation" || /zim_query|wikipedia-offline|buscar_livros|livros-offline/i.test(conteudo)) ferramentas.push(conteudo.slice(0, 220));
  if (m.type === "statusResponse") console.log(`[${seg()}] status: ${conteudo.slice(0, 200)}`);
  if (m.type === "textResponseChunk" || m.type === "fullTextResponse") texto += typeof m.content === "string" ? m.content : (m.content?.text ?? "");
  if (m.from === "@agent" && m.content && !m.type) texto += conteudo;
  if (m.type === "wssFailure") console.log(`[${seg()}] FALHA: ${conteudo}`);
  if (m.type === "awaitingFeedback" || m.type === "awaitingFeedback".toLowerCase()) {
    ws.send(JSON.stringify({ type: "awaitingFeedback", feedback: "exit" }));
  }
};
ws.onclose = () => {
  clearTimeout(fim);
  console.log(`[${seg()}] chamadas de ferramenta vistas: ${ferramentas.length}`);
  ferramentas.slice(0, 4).forEach((f) => console.log("   ->", f));
  console.log("RESPOSTA:", texto.replace(/<think>[\s\S]*?<\/think>/g, "").trim().slice(0, 900));
  process.exit(0);
};
