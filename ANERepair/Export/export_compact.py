"""V49 export repair: fixed64, BC1S convolutions and six independent heads.

Builds MIL directly from the original tensors. No model prediction or training.
The SDK performs the original legal-ID selection on CPU after FP32 output.
"""
from pathlib import Path
from collections import Counter
import hashlib,json,sys
import numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types

REVISION='v49-static64-bc1s-2'

def main():
    weights=np.load('weights.npz')
    source=json.loads(Path('source.json').read_text())
    used=set()
    def W(name):
        used.add(name)
        return weights[name]
    def conv(x,name):
        # A learned [out,in] linear map is the same [out,in,1,1] convolution.
        matrix=W(name+'.weight')
        return mb.conv(x=x,weight=matrix[:,:,None,None],bias=W(name+'.bias'),
                       strides=[1,1],pad_type='valid')
    def norm(x,name):
        # Preserve PyTorch's normalized*gamma+beta order and epsilon.
        return mb.layer_norm(x=x,axes=[1],gamma=W(name+'.weight'),beta=W(name+'.bias'),epsilon=1e-5)

    @mb.program(input_specs=[mb.TensorSpec((1,32),dtype=types.int32),
                            mb.TensorSpec((1,64),dtype=types.int32),
                            mb.TensorSpec((1,32),dtype=types.int32),
                            mb.TensorSpec((1,64),dtype=types.int32)],opset_version=ct.target.iOS18)
    def program(context_ids,pinyin_ids,context_mask,pinyin_mask):
        segment=W('segment.weight')
        position=W('position')
        context=mb.add(x=mb.gather(x=W('char_embedding.weight'),indices=context_ids,axis=0),y=segment[0])
        pinyin=mb.add(x=mb.gather(x=W('pinyin_embedding.weight'),indices=pinyin_ids,axis=0),y=segment[1])
        context=mb.add(x=context,y=position[:32])
        pinyin=mb.add(x=pinyin,y=position[32:96])
        x=mb.expand_dims(x=mb.transpose(x=mb.concat(values=[context,pinyin],axis=1),perm=[0,2,1]),axes=[2])
        valid=mb.expand_dims(x=mb.concat(values=[mb.not_equal(x=context_mask,y=0),
                                               mb.not_equal(x=pinyin_mask,y=0)],axis=1),axes=[2,3])
        for i in range(8):
            name='layers.'+str(i)
            q,k,v=mb.split(x=conv(norm(x,name+'.n1'),name+'.qkv'),num_splits=3,axis=1)
            qs=mb.split(x=q,num_splits=6,axis=1)
            ks=mb.split(x=k,num_splits=6,axis=1)
            vs=mb.split(x=v,num_splits=6,axis=1)
            heads=[]
            for query,key,value in zip(qs,ks,vs):
                # KxQ layout: key position is channel axis, query is last axis.
                key=mb.transpose(x=key,perm=[0,3,2,1])
                score=mb.mul(x=mb.einsum(values=[key,query],equation='nchw,nwhu->nchu'),y=0.125)
                score=mb.select(cond=valid,a=score,b=-10000.)
                attention=mb.softmax(x=score,axis=1)
                heads.append(mb.einsum(values=[value,attention],equation='nchw,nwhu->nchu'))
            x=mb.add(x=x,y=conv(mb.concat(values=heads,axis=1),name+'.proj'))
            hidden=mb.gelu(x=conv(norm(x,name+'.n2'),name+'.up'),mode='TANH_APPROXIMATION')
            x=mb.add(x=x,y=conv(hidden,name+'.down'))
        target=mb.slice_by_size(x=x,begin=[0,0,0,32],size=[1,384,1,64])
        output=conv(norm(target,'final_norm'),'character_output')
        return mb.identity(x=output,name='character_logits')

    assert used==set(weights.files),sorted(set(weights.files)^used)
    inputs=[ct.TensorType(name=name,shape=shape,dtype=np.int32) for name,shape in [
        ('context_ids',(1,32)),('pinyin_ids',(1,64)),('context_mask',(1,32)),('pinyin_mask',(1,64))]]
    model=ct.convert(program,source='milinternal',inputs=inputs,
                     outputs=[ct.TensorType(name='character_logits',dtype=np.float32)],
                     convert_to='mlprogram',minimum_deployment_target=ct.target.iOS18,
                     compute_precision=ct.precision.FLOAT16,skip_model_load=True)
    model.short_description='V49 local1408/global94661, static64 BC1S graph compatibility repair2'
    model.user_defined_metadata.update({
        'source_model':'V49','source_step':str(source['source_step']),
        'checkpoint_sha256':source['checkpoint_sha256'],'model_tensor_sha256':source['model_tensor_sha256'],
        'kernel_version':'v49_v46_text_rank_initials_10h','graph_export_version':REVISION,
        'score_version':'v23-input-sequence-energy-1','weights_changed_in_this_revision':'false',
        'input_pinyin_shape':'1,64','output_layout':'1,8192,1,64',
        'legal_id_selection':'CPU SDK; original 512x136 table; legal-only normalization unchanged',
        'quality_passed':'false','deployment_ready':'false'})
    package=Path('V49PinyinANE64FP16.mlpackage')
    model.save(str(package))
    spec=model.get_spec()
    counts=Counter()
    symbolic=[]
    for function in spec.mlProgram.functions.values():
        for block in function.block_specializations.values():
            for op in block.operations:
                counts[op.type]+=1
                for item in op.outputs:
                    for dim in item.type.tensorType.dimensions:
                        if not dim.HasField('constant'):symbolic.append(item.name)
    forbidden=set(counts)&{'range_1d','gather_along_axis','shape'}
    assert not forbidden,forbidden
    assert not symbolic,sorted(set(symbolic))
    for feature in spec.description.input:
        assert not feature.type.multiArrayType.enumeratedShapes.shapes
        assert not feature.type.multiArrayType.shapeRange.sizeRanges
    record={
        'graph_revision':REVISION,'source_checkpoint_sha256':source['checkpoint_sha256'],
        'source_model_tensor_sha256':source['model_tensor_sha256'],'source_step':94661,'source_local_step':1408,
        'parameters':20730368,'all_source_tensors_mapped':len(used),
        'source_weights_npz_sha256':hashlib.sha256(Path('weights.npz').read_bytes()).hexdigest(),
        'weights_changed_in_this_revision':False,'new_training':False,
        'precision':'FP16 weights/compute; INT32 IDs/masks; FP32 logits',
        'input_shapes':{x.name:list(x.type.multiArrayType.shape) for x in spec.description.input},
        'output_shapes':{x.name:list(x.type.multiArrayType.shape) for x in spec.description.output},
        'dynamic_outputs':symbolic,'operations':dict(counts),'forbidden_dynamic_operations':sorted(forbidden),
        'projection_computes_full_8192_before_gather':True,'legal_id_gather_in_graph':False,
        'graph_bytes':(package/'Data/com.apple.CoreML/model.mlmodel').stat().st_size,
        'weight_blob_bytes':sum(p.stat().st_size for p in package.rglob('*.bin')),
        'coremltools':ct.__version__,'python':sys.version,'numpy':np.__version__,
        'prediction_run':False,'model_executed':False,'Apple_numerical_validation':False,
        'ANE_runtime_verified':False,'user_runs_all_tests':True,
        'references':['https://machinelearning.apple.com/research/neural-engine-transformers',
                      'https://github.com/apple/coremltools/issues/1909']}
    Path('compact_export_record.json').write_text(json.dumps(record,indent=2))
    print(json.dumps(record))

if __name__=='__main__':main()
