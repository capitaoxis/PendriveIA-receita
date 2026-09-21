# Separa quem falou num audio (sherpa-onnx: segmentacao pyannote 3.0 + voz 3D-Speaker), sem rede.
# Uso:
#   python quem-falou.py audio16k.wav                 -> trechos "inicio fim Pessoa N"
#   python quem-falou.py audio16k.wav legenda.srt     -> transcricao "[mm:ss] Pessoa N: texto"
#   --pessoas N   quando se sabe quantas pessoas falaram (acerta mais); sem ele, estima.
#   --nomes "Artur,Paciente"   troca Pessoa 1/2 pelos nomes, na ordem em que cada um fala primeiro.
# O audio precisa estar em WAV 16 kHz mono (o transcrever-audio.ps1 ja converte com o ffmpeg).
# Nada e gravado: o resultado sai no stdout e quem chama decide onde salvar (audio de consulta e dado de saude).
import os, re, sys, wave
import numpy as np
import sherpa_onnx

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELOS = os.path.join(RAIZ, "Ferramentas", "diarizacao")
SEG = os.path.join(MODELOS, "sherpa-onnx-pyannote-segmentation-3-0", "model.onnx")
VOZ = os.path.join(MODELOS, "voz.onnx")
sys.stdout.reconfigure(encoding="utf-8")


def ler_wav(arq):
    with wave.open(arq) as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise SystemExit("O audio precisa ser WAV 16 kHz mono 16 bits.")
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


def separar(amostras, pessoas=0, limiar=0.6):
    cfg = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=SEG), num_threads=4),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=VOZ, num_threads=4),
        # com numero de pessoas conhecido, agrupa em exatamente N; senao, pela distancia entre as vozes
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=pessoas or -1, threshold=limiar),
        min_duration_on=0.3, min_duration_off=0.5)
    if not cfg.validate():
        raise SystemExit("Modelos de separacao de voz nao encontrados em " + MODELOS)
    d = sherpa_onnx.OfflineSpeakerDiarization(cfg)
    r = [(s.start, s.end, s.speaker) for s in d.process(amostras).sort_by_start_time()]
    # "pessoa" com menos de 1 s de fala no audio inteiro e ruido (controle com uma voz so dava uma
    # Pessoa 2 de 0,3 s no meio de uma frase): sai, e o trecho fica com quem estava falando em volta
    total = {}
    for a, b, p in r:
        total[p] = total.get(p, 0) + (b - a)
    if len(total) > 1:
        r = [t for t in r if total[t[2]] >= 1.0] or r
    # renumera na ordem em que cada pessoa fala pela primeira vez (Pessoa 1 = quem abre a conversa)
    ordem = {}
    for _, _, p in r:
        ordem.setdefault(p, len(ordem) + 1)
    return [(a, b, ordem[p]) for a, b, p in r]


def ler_srt(arq):
    def seg(t):
        h, m, s = t.replace(",", ".").split(":")
        return int(h) * 3600 + int(m) * 60 + float(s)
    blocos = re.split(r"\n\s*\n", open(arq, encoding="utf-8-sig", errors="replace").read().strip())
    saida = []
    for b in blocos:
        linhas = b.strip().splitlines()
        tempo = next((l for l in linhas if "-->" in l), None)
        if not tempo:
            continue
        ini, fim = [seg(x.strip()) for x in tempo.split("-->")]
        texto = " ".join(l for l in linhas[linhas.index(tempo) + 1:]).strip()
        if texto:
            saida.append((ini, fim, texto))
    return saida


def quem(ini, fim, trechos):
    """Pessoa com mais tempo de fala dentro do intervalo; sem sobreposicao, a mais proxima."""
    tempo = {}
    for a, b, p in trechos:
        sob = min(fim, b) - max(ini, a)
        if sob > 0:
            tempo[p] = tempo.get(p, 0) + sob
    if tempo:
        return max(tempo, key=tempo.get)
    meio = (ini + fim) / 2
    return min(trechos, key=lambda t: min(abs(meio - t[0]), abs(meio - t[1])))[2] if trechos else 0


def mmss(s):
    s = int(s)
    return f"{s // 3600:d}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:02d}:{s % 60:02d}"


def nome_pessoa(n, nomes):
    """--nomes "Artur,Paciente" troca Pessoa 1 e Pessoa 2; sem nome para aquele numero, fica Pessoa N."""
    return nomes[n - 1] if 0 < n <= len(nomes) and nomes[n - 1] else f"Pessoa {n}"


if __name__ == "__main__":
    a = sys.argv[1:]
    pessoas, nomes = 0, []
    if "--pessoas" in a:
        i = a.index("--pessoas")
        pessoas = int(a[i + 1])
        del a[i:i + 2]
    if "--nomes" in a:
        i = a.index("--nomes")
        nomes = [x.strip() for x in a[i + 1].split(",")]
        del a[i:i + 2]
        if not pessoas:
            pessoas = len(nomes)   # dizer os nomes ja diz quantas pessoas sao
    if not a:
        raise SystemExit(__doc__ or 'uso: quem-falou.py audio16k.wav [legenda.srt] [--pessoas N] [--nomes "A,B"]')
    for p in a[:2]:
        if not os.path.exists(p):
            raise SystemExit("nao encontrei o arquivo: " + p)
    trechos = separar(ler_wav(a[0]), pessoas)
    if len(a) == 1:
        for ini, fim, p in trechos:
            print(f"{ini:7.2f} {fim:7.2f} {nome_pessoa(p, nomes)}")
    else:
        palavras = [(ini, texto, quem(ini, fim, trechos)) for ini, fim, texto in ler_srt(a[1])]
        # precisa de legenda palavra por palavra com horario alinhado (whisper -ml 1 -sow -dtw, sem -nt)
        pessoa = [p for _, _, p in palavras]
        atual, bloco = None, []
        for (ini, texto, _), p in zip(palavras, pessoa):
            if p != atual and bloco:
                print(f"[{mmss(bloco[0][0])}] {nome_pessoa(atual, nomes)}: " + " ".join(t for _, t in bloco) + "\n")
                bloco = []
            atual = p
            bloco.append((ini, texto))
        if bloco:
            print(f"[{mmss(bloco[0][0])}] {nome_pessoa(atual, nomes)}: " + " ".join(t for _, t in bloco))
