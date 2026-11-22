"""Collect available upstream license texts into the Windows distribution."""
from importlib.metadata import distribution
from pathlib import Path
import shutil
import sys

output=Path(sys.argv[1])/"licenses"
output.mkdir(parents=True,exist_ok=True)
for name in ("pycryptodome","pyinstaller"):
    package=distribution(name)
    for entry in package.files or []:
        if str(entry).lower().endswith(("license","license.txt","license.rst","license.md","copying.txt","copying","copyright")):
            source=Path(package.locate_file(entry))
            if source.is_file():shutil.copy2(source,output/(name+"-"+source.name))
for source in Path(sys.base_prefix).glob("LICENSE*"):
    if source.is_file():shutil.copy2(source,output/("Python-"+source.name))
for source in (Path(sys.base_prefix)/"tcl").glob("*/license.terms"):
    shutil.copy2(source,output/(source.parent.name+"-license.terms"))
