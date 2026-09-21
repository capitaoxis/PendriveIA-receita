# Servidor MCP (stdio) que deixa a IA dos Documentos (AnythingLLM) buscar nos livros do pendrive.
# Mesmo indice do livros-busca.py (Livros\indice\livros.db), so leitura, sem rede.
# Registrado em AnythingLLM\dados\storage\plugins\anythingllm_mcp_servers.json como "livros-offline".
import os, sys, importlib.util
from mcp.server.mcpserver import MCPServer

_spec = importlib.util.spec_from_file_location("livros_busca", os.path.join(os.path.dirname(os.path.abspath(__file__)), "livros-busca.py"))
busca = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(busca)

mcp = MCPServer("livros-offline")


@mcp.tool()
def buscar_livros(palavras_chave: str) -> str:
    """Busca trechos nos livros da biblioteca offline (saude, psicologia, ciencias sociais, guias praticos,
    literatura). Use 2 a 4 PALAVRAS-CHAVE em portugues, nao a pergunta inteira (ex.: "quedas idosos",
    "desfralde autismo"). Se vier vazio, tente de novo com menos palavras ou sinonimos.
    Cada trecho vem como [Titulo — Autor] texto. Responda SO com o que os trechos dizem e cite
    [Titulo — Autor]. Se nenhum trecho responder de fato a pergunta, diga que nao encontrou nos livros;
    nunca complete com conhecimento proprio apresentado como se viesse dos livros."""
    achados = busca.buscar(palavras_chave, n=6)
    return achados or "NENHUM TRECHO ENCONTRADO nos livros para: " + palavras_chave


@mcp.tool()
def listar_livros(palavras_chave: str) -> str:
    """Diz QUAIS LIVROS da biblioteca offline falam de um assunto (titulo, autor e quantos trechos
    casaram), sem trazer o texto. Use quando a pergunta for "que livros voce tem sobre X", "tem algum
    livro de X", ou antes de buscar_livros para escolher o assunto. 2 a 4 palavras-chave em portugues.
    Uma linha comecando com "(nenhum livro tem todas as palavras" significa busca frouxa: 1 ou 2
    trechos ali nao querem dizer que o livro trata do assunto."""
    lista = busca.livros_sobre(palavras_chave, n=15)
    return lista or "NENHUM LIVRO ENCONTRADO para: " + palavras_chave


if __name__ == "__main__":
    mcp.run()
