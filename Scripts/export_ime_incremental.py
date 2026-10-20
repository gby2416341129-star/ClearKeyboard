"""One-position Core ML transformer with explicit reusable attention state.

The pinned weights and exact GELU are unchanged. The full-prefix graph is kept
in the build cache only as an independent numerical/performance reference.
"""
import hashlib, json, math, subprocess
from pathlib import Path
import numpy as np
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.proto import FeatureTypes_pb2
from export_ime_coreml import ROOT,build,write_model


def build_incremental(source,output):
    baseline,w=build(source,output.with_name('ClearSentence25M-full.mlmodel'))
    batch,length,d,heads,layers=8,16,448,8,8
    features=[('tokens',datatypes.Array(batch,1)),('positions',datatypes.Array(batch,1)),
        ('past_k',datatypes.Array(layers,batch,length,d)),
        ('past_v',datatypes.Array(layers,batch,length,d)),
        ('write_mask',datatypes.Array(batch,length)),('attention_mask',datatypes.Array(batch,length))]
    outputs=[('log_probs',datatypes.Array(batch,12288)),
        ('new_k',datatypes.Array(batch,layers,d)),('new_v',datatypes.Array(batch,layers,d))]
    b=NeuralNetworkBuilder(features,outputs,disable_rank5_shape_mapping=True)
    def constant(name,array):
        array=np.asarray(array,dtype=np.float32);b.add_load_constant_nd(name,name,array,array.shape);return name
    def add(name,a,c):b.add_add_broadcastable(name,[a,c],name);return name
    def mul(name,a,c):b.add_multiply_broadcastable(name,[a,c],name);return name
    def reshape(name,x,shape):b.add_reshape_static(name,x,name,shape);return name
    def norm(name,x,p):b.add_layer_normalization(name,x,name,(d,),w[p+'.weight'],w[p+'.bias']);return name
    def linear(name,x,p):
        b.add_batched_mat_mul(name,[x],name,weight_matrix_rows=w[p+'.weight'].shape[1],
            weight_matrix_columns=w[p+'.weight'].shape[0],W=w[p+'.weight'].T,bias=w[p+'.bias']);return name
    constant('embedding_table',w['tok.weight']);constant('position_table',w['pos.weight'])
    b.add_gather('embedding',['embedding_table','tokens'],'embedding',axis=0)
    b.add_gather('pos_embedding',['position_table','positions'],'pos_embedding',axis=0)
    x=add('embedded','embedding','pos_embedding')
    write=reshape('expanded_write','write_mask',(batch,1,length,1))
    mask=reshape('expanded_mask','attention_mask',(batch,1,1,length))
    constant('attention_scale',np.array([1/math.sqrt(d//heads)]))
    keys,values=[],[]
    for layer in range(layers):
        p=f'blocks.{layer}.';n=f'b{layer}_'
        qkv=linear(n+'qkv',norm(n+'ln1',x,p+'ln1'),p+'qkv')
        q,k,v=[n+c for c in 'qkv'];b.add_split_nd(n+'split',qkv,[q,k,v],axis=-1,num_splits=3)
        keys.append(k);values.append(v)
        for tensor in (q,k,v):
            reshape(tensor+'_reshape',tensor,(batch,1,heads,d//heads))
            b.add_transpose(tensor+'_heads',[0,2,1,3],tensor+'_reshape',tensor+'_heads')
        for kind in ('k','v'):
            name=n+'past_'+kind
            b.add_slice_static(name,'past_'+kind,name,[layer,0,0,0],[layer+1,batch,length,d],[1,1,1,1],
                [False]*4,[False]*4)
            b.add_squeeze(name+'_squeeze',name,name+'_squeeze',axes=[0])
            reshape(name+'_reshape',name+'_squeeze',(batch,length,heads,d//heads))
            b.add_transpose(name+'_heads',[0,2,1,3],name+'_reshape',name+'_heads')
            current=mul(n+'current_'+kind,n+kind+'_heads',write)
            add(n+'all_'+kind,name+'_heads',current)
        b.add_batched_mat_mul(n+'qk',[q+'_heads',n+'all_k'],n+'qk',transpose_b=True)
        attention=add(n+'masked',mul(n+'scaled',n+'qk','attention_scale'),mask)
        b.add_softmax_nd(n+'attention',attention,n+'attention',axis=-1)
        b.add_batched_mat_mul(n+'av',[n+'attention',n+'all_v'],n+'av')
        b.add_transpose(n+'unheads',[0,2,1,3],n+'av',n+'unheads')
        joined=reshape(n+'joined',n+'unheads',(batch,1,d))
        x=add(n+'residual1',x,linear(n+'projected',joined,p+'proj'))
        f=linear(n+'fc',norm(n+'ln2',x,p+'ln2'),p+'fc')
        b.add_gelu(n+'gelu',f,n+'gelu',mode='EXACT')
        x=add(n+'residual2',x,linear(n+'out',n+'gelu',p+'out'))
    hidden=reshape('last_hidden',norm('final_norm',x,'ln_f'),(batch,d))
    b.add_batched_mat_mul('logits',[hidden,'embedding_table'],'logits',transpose_b=True)
    b.add_reduce_logsumexp('normalizers','logits','normalizers',axes=[-1],keepdims=True)
    b.add_subtract_broadcastable('log_probs',['logits','normalizers'],'log_probs')
    b.add_concat_nd('new_k',keys,'new_k',axis=1);b.add_concat_nd('new_v',values,'new_v',axis=1)
    spec=b.spec
    for feature in list(spec.description.input)+list(spec.description.output):
        feature.type.multiArrayType.dataType=FeatureTypes_pb2.ArrayFeatureType.FLOAT32
    spec.specificationVersion=max(spec.specificationVersion,5)
    spec.description.metadata.CopyFrom(baseline.description.metadata)
    spec.description.metadata.shortDescription='ClearKeyboard 25M incremental offline prefix predictor'
    spec.description.metadata.userDefined['shape']='8x1; explicit 16-position KV state; no prefix recomputation'
    spec.description.metadata.userDefined['state_format']='clear-kv-v1: layers,batch,time,hidden -> batch,layers,hidden'
    write_model(spec,output)
    return spec,w


if __name__=='__main__':
    output=ROOT/'.rime-cache/ClearSentence25M.mlmodel'
    spec,_=build_incremental(ROOT/'.rime-cache/ime-25m/sentence-model.safetensors',output)
    resources=ROOT/'Core/Resources/Rime'
    subprocess.run(['xcrun','coremlcompiler','compile',str(output),str(resources)],check=True)
    (resources/'CoreML25M-validation.json').write_bytes((ROOT/'Data/Rime/coreml25m-incremental-validation.json').read_bytes())
    compiled=resources/'ClearSentence25M.mlmodelc'
    files={str(p.relative_to(resources)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(compiled.rglob('*')) if p.is_file()}
    if not files:raise RuntimeError('Core ML compilation produced no assets')
    manifest=dict(source_sha256=spec.description.metadata.userDefined['source_sha256'],
        state_format='clear-kv-v1',model_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),files=files)
    (resources/'CoreML25M-manifest.json').write_text(json.dumps(manifest,sort_keys=True),encoding='utf8')
