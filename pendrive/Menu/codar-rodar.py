# O Python do pendrive e "embutido" (python312._pth): ele NAO poe a pasta do script nem a pasta atual
# no sys.path, entao "import calc" ao lado do teste falha. O /rodar do codar passa por aqui para
# funcionar como um Python normal:  python codar-rodar.py script.py args  |  python codar-rodar.py -m modulo args
import os, runpy, sys

a = sys.argv[1:]
sys.path.insert(0, os.getcwd())
if not a:
    print("uso: codar-rodar.py script.py [args] | -m modulo [args]"); sys.exit(2)
if a[0] == "-m" and len(a) > 1:
    sys.argv = [a[1]] + a[2:]
    runpy.run_module(a[1], run_name="__main__", alter_sys=True)
elif a[0] == "-c" and len(a) > 1:
    sys.argv = ["-c"] + a[2:]
    exec(compile(a[1], "<string>", "exec"), {"__name__": "__main__"})
else:
    sys.path.insert(0, os.path.dirname(os.path.abspath(a[0])))
    sys.argv = a
    runpy.run_path(a[0], run_name="__main__")
