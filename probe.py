import os, sys, subprocess

bat = sys.argv[1]  # absolute path to isabelle.bat

print("===PROBE_D_BEGIN===", flush=True)
# native Windows python view via os.popen
try:
    out = os.popen(bat + " getenv -b ISABELLE_HOME_USER").read()
except Exception as e:
    out = "EXC:" + repr(e)
print("POPEN=" + repr(out), flush=True)
print("ENV=" + repr(os.environ.get("ISABELLE_HOME_USER")), flush=True)

# also try subprocess to see exit code and both streams
try:
    r = subprocess.run([bat, "getenv", "-b", "ISABELLE_HOME_USER"],
                       capture_output=True, text=True, timeout=300)
    print("SUBPROC_RC=" + repr(r.returncode), flush=True)
    print("SUBPROC_STDOUT=" + repr(r.stdout), flush=True)
    print("SUBPROC_STDERR=" + repr(r.stderr), flush=True)
except Exception as e:
    print("SUBPROC_EXC=" + repr(e), flush=True)
print("===PROBE_D_END===", flush=True)
