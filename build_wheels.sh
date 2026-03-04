#!/bin/bash
set -e

echo "=== 1. Install System Dependencies & uv ==="
apt-get update
apt-get install -y curl git build-essential
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.cargo/bin:$PATH"
source $HOME/.local/bin/env
uv --version

echo "=== 2. Setup CUDA Environment ==="
export CUDA_HOME=/usr/local/cuda
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
export FORCE_CUDA=1
export BUILD_CUDA_EXT=1
export TORCH_CUDA_ARCH_LIST="7.0;7.5;8.0;8.6;8.9;9.0"

nvcc --version || echo "nvcc not found!"
nvidia-smi || echo "No GPU available in build container (Expected)"

# 计算 wheel 的 CUDA 后缀
TORCH_SHORT=$(echo $TORCH_VERSION | cut -d. -f1,2)
if [ "$CUDA_VERSION" == "cpu" ]; then
    export WHEEL_SUFFIX="+cpu"
else
    export WHEEL_SUFFIX="+cu$(echo $CUDA_VERSION | tr -d '.')torch${TORCH_SHORT}"
fi

echo "=== 3. Checkout Target Source Code ==="
git clone https://github.com/ModelCloud/GPTQModel.git /GPTQModel
cd /GPTQModel
git checkout $TARGET_VERSION

echo "=== 4. Loop Through Python Versions ==="
# 从传入的环境变量获取需要遍历的 Python 版本列表
for PY_VER in $PYTHON_VERSIONS; do
    echo "========================================================="
    echo "🚀 Building for Python $PY_VER with CUDA $CUDA_VERSION"
    echo "========================================================="

    # 清理之前的构建缓存，防止多 Python 版本污染和磁盘写满
    rm -rf build .venv dist/*.whl

    uv python install $PY_VER
    uv venv .venv --python $PY_VER
    source .venv/bin/activate

    echo "--- Installing pip dependencies via uv ---"
    uv pip install --upgrade pip setuptools wheel build twine
    uv pip install torch==$TORCH_VERSION --index-url $TORCH_INDEX
    uv pip install numpy transformers accelerate sentencepiece

    echo "--- Verifying PyTorch Environment ---"
    python -c "import torch; print(f'PyTorch: {torch.__version__} | CUDA available: {torch.cuda.is_available()}')"

    echo "--- Building Wheel ---"
    python setup.py bdist_wheel

    echo "--- Renaming and Testing Wheel ---"
    cd dist
    for file in *.whl; do
        if [[ "$file" == *"gptqmodel"* ]] && [[ ! "$file" =~ \+(cu|cpu) ]]; then
            # 给 whl 文件加上 CUDA tag (例如: +cu126)
            newname=$(echo "$file" | sed "s/-cp/${WHEEL_SUFFIX}-cp/")
            mv "$file" "$newname"
            echo "Renamed: $file -> $newname"
            
            # 强行安装刚刚构建的 wheel 并测试 import
            uv pip install "$newname" --force-reinstall --no-deps
            python -c "import gptqmodel; print('✅ GPTQModel imported successfully!')"
            
            # 将最终成果拷贝到挂载的宿主机输出目录
            cp "$newname" /workspace/output_wheels/
        fi
    done
    cd ..

    # 退出当前虚拟环境，准备下一个 Python 版本
    deactivate
done

# 将生成的文件夹权限交还给宿主机用户，防止 Azure Artifacts 发布时遇到 Permission Denied
chown -R $HOST_UID:$HOST_GID /workspace/output_wheels