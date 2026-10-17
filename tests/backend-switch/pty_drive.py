#!/usr/bin/env python3
"""T09.3.8a — Roda um comando num pseudo-terminal REAL (o filho tem terminal de controle, /dev/tty existe) e digita as
respostas quando cada prompt aparece. Serve para provar a entrada interativa de senha (read -s, sem eco).

  pty_drive.py SAIDA 'prompt1=resposta1' 'prompt2=resposta2' -- comando [args...]

SAIDA recebe tudo o que o terminal mostrou (inclusive um eco, se houvesse). Código de saída = o do comando.
Só laboratório: as respostas vêm da linha de comando (senhas fictícias)."""
import os, pty, select, sys, time

out_path = sys.argv[1]
sep = sys.argv.index('--')
answers = [a.split('=', 1) for a in sys.argv[2:sep]]
cmd = sys.argv[sep + 1:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf = b''
pending = list(answers)
deadline = time.time() + 120
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if r:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        buf += data
    if pending and pending[0][0].encode() in buf:
        os.write(fd, (pending.pop(0)[1] + '\n').encode())
        buf += b'\n<<digitado>>\n'
    try:
        done, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        break
    if done:
        try:
            while select.select([fd], [], [], 0.2)[0]:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                buf += chunk
        except OSError:
            pass
        open(out_path, 'wb').write(buf)
        sys.exit(os.waitstatus_to_exitcode(status))
if time.time() < deadline:  # o terminal fechou: o filho terminou
    _, status = os.waitpid(pid, 0)
    open(out_path, "wb").write(buf)
    sys.exit(os.waitstatus_to_exitcode(status))
open(out_path, "wb").write(buf)
os.kill(pid, 9)
sys.exit(124)
