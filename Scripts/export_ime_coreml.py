"""Independent fixed-shape Core ML graph for the pinned 4M IME scorer.

Builds protobuf only; Windows cannot execute Core ML or certify ANE placement.
"""
import os
os.environ['OPENBLAS_NUM_THREADS']='1'
from pathlib import Path
import json,math,struct,sys,hashlib
ROOT=Path(__file__).resolve().parents[1]
import numpy as np
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.proto import FeatureTypes_pb2


def build(source,output):
    data=source.read_bytes()
    assert hashlib.sha256(data).hexdigest()=='86ac529510cb3b4968a5e6ade83ec8080f5b34a0a681e75c362accbbd387d1c1'
    n=struct.unpack_from('<Q',data)[0]; header=json.loads(data[8:8+n]);metadata=header.pop('__metadata__')
    w={}
    for name,item in header.items():
        a,b=item['data_offsets']; dtype='i1' if item['dtype']=='I8' else '<f4'
        w[name]=np.frombuffer(data,dtype,count=math.prod(item['shape']),offset=8+n+a).reshape(item['shape']).astype(np.float32)
    for name in list(w):
        if name.endswith('.scale'): w[name[:-6]]*=w[name][:,None]
    batch,length,d,heads=9,16,192,4
    features=[('tokens',datatypes.Array(batch,length)),('targets',datatypes.Array(batch,length,3)),('mask',datatypes.Array(batch,length))]
    builder=NeuralNetworkBuilder(features,[('scores',datatypes.Array(batch))],disable_rank5_shape_mapping=True)
    # Gather indices can be integer-valued float32 in the neural-network format.
    def constant(name,arr):
        arr=np.asarray(arr,dtype=np.float32)
        builder.add_load_constant_nd(name,name,arr,arr.shape)
        return name
    def add(name,a,b):builder.add_add_broadcastable(name,[a,b],name);return name
    def mul(name,a,b):builder.add_multiply_broadcastable(name,[a,b],name);return name
    def linear(name,x,prefix):
        builder.add_batched_mat_mul(name,[x],name,weight_matrix_rows=w[prefix+'.weight'].shape[1],weight_matrix_columns=w[prefix+'.weight'].shape[0],W=w[prefix+'.weight'].T,bias=w[prefix+'.bias'])
        return name
    def norm(name,x,prefix):
        builder.add_layer_normalization(name,x,name,(d,),w[prefix+'.weight'],w[prefix+'.bias'])
        return name
    constant('embedding_table',w['tok.weight'])
    builder.add_gather('embedding',['embedding_table','tokens'],'embedding',axis=0)
    x=add('embedded','embedding',constant('positions',w['pos.weight'][:length]))
    causal=np.where(np.triu(np.ones((length,length),dtype=bool),k=1),-10000.,0.)
    constant('causal',causal)
    constant('attention_scale',np.array([1/math.sqrt(d//heads)]))
    for layer in range(6):
        p=f'blocks.{layer}.'; name=f'b{layer}_'
        qkv=linear(name+'qkv',norm(name+'ln1',x,p+'ln1'),p+'qkv')
        q,k,v=[name+c for c in 'qkv']
        builder.add_split_nd(name+'split',qkv,[q,k,v],axis=-1,num_splits=3)
        for tensor in (q,k,v):
            builder.add_reshape_static(tensor+'_reshape',tensor,tensor+'_reshape',(batch,length,heads,d//heads))
            builder.add_transpose(tensor+'_heads',[0,2,1,3],tensor+'_reshape',tensor+'_heads')
        builder.add_batched_mat_mul(name+'qk',[q+'_heads',k+'_heads'],name+'qk',transpose_b=True)
        a=add(name+'masked',mul(name+'scaled',name+'qk','attention_scale'),'causal')
        builder.add_softmax_nd(name+'attention',a,name+'attention',axis=-1)
        builder.add_batched_mat_mul(name+'av',[name+'attention',v+'_heads'],name+'av')
        builder.add_transpose(name+'unheads',[0,2,1,3],name+'av',name+'unheads')
        builder.add_reshape_static(name+'joined',name+'unheads',name+'joined',(batch,length,d))
        x=add(name+'residual1',x,linear(name+'projected',name+'joined',p+'proj'))
        f=linear(name+'fc',norm(name+'ln2',x,p+'ln2'),p+'fc')
        builder.add_gelu(name+'gelu',f,name+'gelu',mode='EXACT')
        x=add(name+'residual2',x,linear(name+'out',name+'gelu',p+'out'))
    hidden=norm('final_norm',x,'ln_f')
    builder.add_batched_mat_mul('logits',[hidden,'embedding_table'],'logits',transpose_b=True)
    builder.add_reduce_logsumexp('normalizers','logits','normalizers',axes=[-1],keepdims=False)
    builder.add_gather_nd('target_logits',['logits','targets'],'target_logits')
    builder.add_subtract_broadcastable('logprobs',['target_logits','normalizers'],'logprobs')
    mul('selected','logprobs','mask')
    builder.add_reduce_sum('sum_logprobs','selected','sum_logprobs',axes=[1],keepdims=False)
    builder.add_reduce_sum('length','mask','length',axes=[1],keepdims=False)
    builder.add_divide_broadcastable('scores',['sum_logprobs','length'],'scores')
    spec=builder.spec
    for feature in list(spec.description.input)+list(spec.description.output):
        feature.type.multiArrayType.dataType=FeatureTypes_pb2.ArrayFeatureType.FLOAT32
    spec.specificationVersion=max(spec.specificationVersion,5)
    spec.description.metadata.shortDescription='ClearKeyboard 4M offline candidate scorer'
    spec.description.metadata.license=metadata['license']
    for key,value in metadata.items():spec.description.metadata.userDefined[key]=value
    spec.description.metadata.userDefined['source_sha256']=hashlib.sha256(data).hexdigest()
    spec.description.metadata.userDefined['shape']='9x16; BOS plus candidate shifted right, no implicit truncation'
    def compress(message):
        if message.DESCRIPTOR.full_name.endswith('.WeightParams') and len(message.floatValue)>1000:
            message.float16Value=np.array(message.floatValue,dtype='<f2').tobytes();message.ClearField('floatValue')
        for descriptor,value in message.ListFields():
            if descriptor.type==descriptor.TYPE_MESSAGE:
                if descriptor.label==descriptor.LABEL_REPEATED:
                    if descriptor.message_type.GetOptions().map_entry:continue
                    for child in value:compress(child)
                else:compress(value)
        if message.DESCRIPTOR.full_name.endswith('.BatchedMatMulLayerParams') and message.weights.float16Value and message.hasBias:
            message.bias.float16Value=np.array(message.bias.floatValue,dtype='<f2').tobytes()
            message.bias.ClearField('floatValue')
    compress(spec)
    output.write_bytes(spec.SerializeToString(deterministic=True))
    print(json.dumps(dict(path=str(output),bytes=output.stat().st_size,layers=len(spec.neuralNetwork.layers),sha256=hashlib.sha256(output.read_bytes()).hexdigest())))
    return spec,w


if __name__=='__main__':
    import subprocess
    source=ROOT/'.rime-cache/ime-4m/sentence-model.safetensors'
    output=ROOT/'.rime-cache/ClearSentence4M.mlmodel'
    spec,_=build(source,output)
    resources=ROOT/'Core/Resources/Rime'
    subprocess.run(['xcrun','coremlcompiler','compile',str(output),str(resources)],check=True)
    (resources/'CoreML4M-validation.json').write_bytes((ROOT/'Data/Rime/coreml4m-validation.json').read_bytes())
    compiled=resources/'ClearSentence4M.mlmodelc'
    files={str(p.relative_to(resources)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(compiled.rglob('*')) if p.is_file()}
    if not files:raise RuntimeError('Core ML compilation produced no assets')
    manifest=dict(source_sha256=spec.description.metadata.userDefined['source_sha256'],model_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),files=files)
    (resources/'CoreML4M-manifest.json').write_text(json.dumps(manifest,sort_keys=True),encoding='utf-8')

