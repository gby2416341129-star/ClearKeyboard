"""Experiment: shared-weight incremental and whole-candidate Core ML functions.

Uses the same pinned int8 weights and original attribution. No training occurs.
Build-only mode validates MIL types on Windows; execution requires macOS.
"""
import argparse,hashlib,json,math,struct,subprocess
from pathlib import Path
import numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb

SOURCE_SHA='0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469'
B,L,D,H,N,V=8,16,448,8,8,12288
SCORE_BATCH=4

def load(path):
    data=path.read_bytes();assert hashlib.sha256(data).hexdigest()==SOURCE_SHA
    offset=struct.unpack_from('<Q',data)[0];header=json.loads(data[8:8+offset]);metadata=header.pop('__metadata__');arrays={}
    for name,spec in header.items():
        start,end=spec['data_offsets'];dtype='i1' if spec['dtype']=='I8' else '<f4'
        arrays[name]=np.frombuffer(data,dtype=dtype,offset=8+offset+start,count=math.prod(spec['shape'])).reshape(spec['shape'])
        assert arrays[name].nbytes==end-start
    assert metadata['attribution'] and metadata['license']=='Apache-2.0'
    return arrays,metadata

def parameters(arrays):
    values={}
    for name,array in arrays.items():
        if name.endswith('.scale'):continue
        label=name.replace('.','_')
        if array.dtype==np.int8:
            values[name]=mb.constexpr_affine_dequantize(quantized_data=array,
                scale=arrays[name+'.scale'],zero_point=np.int8(0),axis=np.int32(0),name=label)
        else:values[name]=mb.const(val=array,name=label)
    return values

def norm(x,w,name):
    return mb.layer_norm(x=x,axes=[-1],gamma=w[name+'.weight'],beta=w[name+'.bias'],epsilon=np.float32(1e-5))

def linear(x,w,name):return mb.linear(x=x,weight=w[name+'.weight'],bias=w[name+'.bias'])

def project_heads(tensor,length,batch=B):return mb.transpose(x=mb.reshape(x=tensor,shape=[batch,length,H,D//H]),perm=[0,2,1,3])

def programs(arrays):
    @mb.program(input_specs=[mb.TensorSpec(shape=(B,1)),mb.TensorSpec(shape=(B,1)),
        mb.TensorSpec(shape=(N,B,L,D)),mb.TensorSpec(shape=(N,B,L,D)),
        mb.TensorSpec(shape=(B,L)),mb.TensorSpec(shape=(B,L))],opset_version=ct.target.iOS18)
    def step(tokens,positions,past_k,past_v,write_mask,attention_mask):
        w=parameters(arrays)
        token=mb.cast(x=tokens,dtype='int32');position=mb.cast(x=positions,dtype='int32')
        x=mb.add(x=mb.gather(x=w['tok.weight'],indices=token,axis=0),y=mb.gather(x=w['pos.weight'],indices=position,axis=0))
        write=mb.reshape(x=write_mask,shape=[B,1,L,1]);mask=mb.reshape(x=attention_mask,shape=[B,1,1,L]);keys=[];values=[]
        for layer in range(N):
            p=f'blocks.{layer}.'
            q,k,v=mb.split(x=linear(norm(x,w,p+'ln1'),w,p+'qkv'),axis=-1,num_splits=3)
            keys.append(k);values.append(v)
            q,k,v=[project_heads(value,1) for value in [q,k,v]]
            old_k=project_heads(mb.gather(x=past_k,indices=np.int32(layer),axis=0),L)
            old_v=project_heads(mb.gather(x=past_v,indices=np.int32(layer),axis=0),L)
            k=mb.add(x=old_k,y=mb.mul(x=k,y=write));v=mb.add(x=old_v,y=mb.mul(x=v,y=write))
            attention=mb.softmax(x=mb.add(x=mb.mul(x=mb.matmul(x=q,y=k,transpose_y=True),y=np.float32(1/math.sqrt(D//H))),y=mask),axis=-1)
            joined=mb.reshape(x=mb.transpose(x=mb.matmul(x=attention,y=v),perm=[0,2,1,3]),shape=[B,1,D])
            x=mb.add(x=x,y=linear(joined,w,p+'proj'))
            expanded=mb.gelu(x=linear(norm(x,w,p+'ln2'),w,p+'fc'),mode='EXACT')
            x=mb.add(x=x,y=linear(expanded,w,p+'out'))
        hidden=mb.reshape(x=norm(x,w,'ln_f'),shape=[B,D])
        logits=mb.matmul(x=hidden,y=w['tok.weight'],transpose_y=True,name='vocab_projection')
        probs=mb.sub(x=logits,y=mb.reduce_log_sum_exp(x=logits,axes=[-1],keep_dims=True),name='log_probs')
        return probs,mb.concat(values=keys,axis=1,name='new_k'),mb.concat(values=values,axis=1,name='new_v')

    @mb.program(input_specs=[mb.TensorSpec(shape=(SCORE_BATCH,L),dtype=ct.converters.mil.mil.types.int32),
        mb.TensorSpec(shape=(SCORE_BATCH,L),dtype=ct.converters.mil.mil.types.int32),mb.TensorSpec(shape=(SCORE_BATCH,L))],opset_version=ct.target.iOS18)
    def score(tokens,targets,valid_mask):
        w=parameters(arrays)
        positions=mb.gather(x=w['pos.weight'],indices=np.arange(L,dtype=np.int32),axis=0)
        x=mb.add(x=mb.gather(x=w['tok.weight'],indices=tokens,axis=0),y=positions)
        causal=np.where(np.triu(np.ones((L,L),dtype=bool),k=1),np.float32(-10000),np.float32(0))
        for layer in range(N):
            p=f'blocks.{layer}.'
            q,k,v=mb.split(x=linear(norm(x,w,p+'ln1'),w,p+'qkv'),axis=-1,num_splits=3)
            q,k,v=[project_heads(value,L,SCORE_BATCH) for value in [q,k,v]]
            attention=mb.softmax(x=mb.add(x=mb.mul(x=mb.matmul(x=q,y=k,transpose_y=True),y=np.float32(1/math.sqrt(D//H))),y=causal),axis=-1)
            joined=mb.reshape(x=mb.transpose(x=mb.matmul(x=attention,y=v),perm=[0,2,1,3]),shape=[SCORE_BATCH,L,D])
            x=mb.add(x=x,y=linear(joined,w,p+'proj'))
            expanded=mb.gelu(x=linear(norm(x,w,p+'ln2'),w,p+'fc'),mode='EXACT')
            x=mb.add(x=x,y=linear(expanded,w,p+'out'))
        hidden=norm(x,w,'ln_f')
        logits=mb.matmul(x=hidden,y=w['tok.weight'],transpose_y=True,name='vocab_projection')
        log_probs=mb.sub(x=logits,y=mb.reduce_log_sum_exp(x=logits,axes=[-1],keep_dims=True))
        selected=mb.gather_along_axis(x=log_probs,indices=mb.expand_dims(x=targets,axes=[-1]),axis=-1)
        logp=mb.squeeze(x=selected,axes=[-1])
        total=mb.reduce_sum(x=mb.mul(x=logp,y=valid_mask,name='score_masked_logp'),axes=[-1],keep_dims=False)
        length=mb.maximum(x=mb.reduce_sum(x=valid_mask,axes=[-1],keep_dims=False),y=np.float32(1))
        return mb.real_div(x=total,y=length,name='mean_scores')
    return step,score

def export(root,build_only=False):
    arrays,metadata=load(root/'.rime-cache/ime-25m/sentence-model.safetensors')
    step,score=programs(arrays)
    counts={name:len(program.functions['main'].operations) for name,program in [('step',step),('score',score)]}
    if build_only:
        print(json.dumps({'status':'MIL_typecheck_passed','ops':counts,'executionVerified':False}));return
    target=root/'.rime-cache/shared25m';target.mkdir(parents=True,exist_ok=True)
    paths={}
    for name,program in [('step',step),('score',score)]:
        names=['log_probs','new_k','new_v'] if name=='step' else ['mean_scores']
        model=ct.convert(program,convert_to='mlprogram',minimum_deployment_target=ct.target.iOS18,
            # Keep probability normalization and final reductions in float32;
            # half normalization drift must not change sentence ranking.
            compute_precision=ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in
                {'layer_norm','softmax','reduce_log_sum_exp','sub','gather_along_axis','squeeze','reduce_sum','real_div'} and op.name not in {'score_masked_logp','vocab_projection'}),
            outputs=[ct.TensorType(name=value,dtype=np.float32) for value in names],skip_model_load=True)
        for key,value in metadata.items():model.user_defined_metadata[key]=value
        model.user_defined_metadata['source_sha256']=SOURCE_SHA
        model.user_defined_metadata['state_format']='clear-kv-v1: layers,batch,time,hidden -> batch,layers,hidden'
        model.license=metadata['license']
        path=target/(name+'.mlpackage');model.save(str(path));paths[name]=path
    descriptor=ct.utils.MultiFunctionDescriptor()
    for name,path in paths.items():descriptor.add_function(str(path),src_function_name='main',target_function_name=name)
    descriptor.default_function_name='step'
    combined=target/'merged.mlpackage';ct.utils.save_multifunction(descriptor,str(combined))
    # The merge utility builds a fresh description; retain the source metadata.
    merged=ct.models.MLModel(str(combined),skip_model_load=True,function_name='step')
    for key,value in metadata.items():merged.user_defined_metadata[key]=value
    merged.user_defined_metadata['source_sha256']=SOURCE_SHA
    merged.user_defined_metadata['state_format']='clear-kv-v1: layers,batch,time,hidden -> batch,layers,hidden'
    merged.user_defined_metadata['score_format']='clear-score-v1: 4x16 tokens,targets,valid_mask -> 4 means'
    merged.user_defined_metadata['compute_precision']='mixed float16 transformer and float32 probabilities; original int8 weights'
    merged.license=metadata['license']
    final=target/'ClearSentence25M.mlpackage';merged.save(str(final))
    size=lambda path:sum(p.stat().st_size for p in path.rglob('*') if p.is_file())
    weights=lambda path:sum(p.stat().st_size for p in path.rglob('*.bin'))
    sizes={name:size(path) for name,path in paths.items()};sizes['combined']=size(final)
    blob_bytes={name:weights(path) for name,path in paths.items()};blob_bytes['combined']=weights(final)
    assert blob_bytes['combined']<max(blob_bytes['step'],blob_bytes['score'])*1.03+262144,blob_bytes
    result={'status':'exported','source_sha256':SOURCE_SHA,'computePrecision':'mixed-float16-float32','sizes':sizes,'weightBlobBytes':blob_bytes,'ops':counts,'model':str(final)}
    (target/'export-result.json').write_text(json.dumps(result,indent=2),encoding='utf8');print(json.dumps(result),flush=True)
    resources=root/'Core/Resources/Rime';resources.mkdir(parents=True,exist_ok=True)
    subprocess.run(['xcrun','coremlcompiler','compile',str(final),str(resources)],check=True)
    compiled=resources/'ClearSentence25M.mlmodelc'
    files={str(p.relative_to(resources)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(compiled.rglob('*')) if p.is_file()}
    assert files
    manifest={'source_sha256':SOURCE_SHA,'state_format':'clear-kv-v1','score_format':'clear-score-v1',
        'model_sha256':hashlib.sha256((final/'Data/com.apple.CoreML/model.mlmodel').read_bytes()).hexdigest(),'files':files}
    (resources/'CoreML25M-manifest.json').write_text(json.dumps(manifest,sort_keys=True),encoding='utf8')
    (resources/'CoreML25M-validation.json').write_bytes((root/'Data/Rime/coreml25m-incremental-validation.json').read_bytes())
    (resources/'CoreML25M-score-validation.json').write_bytes((root/'Tests/Evaluation/coreml-score-reference.json').read_bytes())

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1]);parser.add_argument('--build-only',action='store_true');args=parser.parse_args();export(args.root,args.build_only)
