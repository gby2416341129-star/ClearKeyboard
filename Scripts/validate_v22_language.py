"""Build-time structural/reference validation of the SHA-bound mapped dictionary."""
from pathlib import Path
import struct,math
def validate(root):
    d=Path(root)/'Native/V21NativeIME/Sources/V21NativeIME/Resources'
    old=(d/'V19Resources.bin').read_bytes();at=88+8192*4
    for _ in range(411):n=struct.unpack_from('<H',old,at)[0];at+=2+n
    legal=[]
    for _ in range(512):
        n=struct.unpack_from('<H',old,at)[0];at+=2;legal.append(set(struct.unpack_from('<'+str(n)+'H',old,at)));at+=2*n
    b=(d/'V22Language.bin').read_bytes();assert b[:8]==b'CLRLEX02'
    version,nchars,count,width,records,source=struct.unpack_from('<6I',b,8)
    assert version==2 and nchars==8192 and count<=2000000 and width==12 and source==1
    assert records==32+8192*2+count*8 and records<=len(b)
    for i,p in enumerate(struct.unpack_from('<8192H',b,32)):assert p==65535 or p<411 and (i<2 or i in legal[p])
    offsets=struct.unpack_from('<'+str(count)+'I',b,32+8192*2)
    order=struct.unpack_from('<'+str(count)+'I',b,32+8192*2+count*4)
    assert len(set(order))==count and (not order or min(order)==0 and max(order)==count-1)
    expected=records;previous=None
    for off in offsets:
        assert off==expected and off%4==0 and off+16<=len(b)
        n,flags,reserved,lp,mass,confidence=struct.unpack_from('<BBHfff',b,off);expected=off+16+4*n
        assert 2<=n<=12 and expected<=len(b) and flags>0 and reserved==0
        assert all(math.isfinite(x) for x in (lp,mass,confidence)) and lp<0 and mass+1e-4>=lp and 0<=confidence<=1
        ids=struct.unpack_from('<'+str(n)+'H',b,off+16);py=struct.unpack_from('<'+str(n)+'H',b,off+16+n*2)
        assert all(2<=c<8192 and 2<=p<411 and c in legal[p] for c,p in zip(ids,py))
        key=(ids,py);assert previous is None or previous<key;previous=key
    assert expected==len(b)
    previous=None
    for i in order:
        off=offsets[i];n=b[off];py=struct.unpack_from('<'+str(n)+'H',b,off+16+n*2)
        assert previous is None or previous<=py;previous=py
    print('Mapped V22 dictionary structure, reference IDs and sorted indices verified; no inference.')
if __name__=='__main__':validate(Path(__file__).resolve().parents[1])
