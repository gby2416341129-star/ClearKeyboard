"""Direct macOS worker checks. Only private visibility changes in a test copy."""
import hashlib,json,subprocess
from pathlib import Path
import coremltools as ct
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder

ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/'.rime-cache/worker-check';BUILD.mkdir(parents=True,exist_ok=True)
source=(ROOT/'Core/CoreMLSentence.swift').read_text(encoding='utf8')
copied=BUILD/'CoreMLSentence-visible.swift'
copied.write_text(source.replace('private ',''),encoding='utf8')
builder=NeuralNetworkBuilder([('required_input',datatypes.Array(1))],[('output',datatypes.Array(1))])
builder.add_activation(name='copy',non_linearity='RELU',input_name='required_input',output_name='output')
fixture=BUILD/'WorkerFault.mlmodel'
ct.models.MLModel(builder.spec,skip_model_load=True).save(str(fixture))
subprocess.run(['xcrun','coremlcompiler','compile',str(fixture),str(BUILD)],check=True)
executable=BUILD/'test-worker'
subprocess.run(['swiftc','-O','-parse-as-library',str(ROOT/'Core/CoreMLPrefixState.swift'),str(copied),
    str(ROOT/'Scripts/test_coreml_worker.swift'),'-o',str(executable)],check=True)
subprocess.run([str(executable),str(ROOT/'Core/Resources/Rime'),str(BUILD/'WorkerFault.mlmodelc')],check=True)
print(json.dumps({'workerSourceSHA256':hashlib.sha256(source.encode()).hexdigest(),
    'testCopyTransformation':'remove private access modifiers only; production request execution unchanged',
    'iOSRuntimeTestsRun':False}))
