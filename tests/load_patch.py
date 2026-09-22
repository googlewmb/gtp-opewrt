"""测试辅助：按文件名加载编号补丁模块。"""
import importlib.util
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1] / 'patch'
sys.path.insert(0, str(ROOT))
def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
