const deleteGesture = {id:null,startY:0,direction:0,used:false,button:null,timer:null,repeat:null};
let deletionUndo = null;
window.deleteSwipeActive = false; window.suppressDeleteClick = false;
window.clearDeletionUndo = () => { deletionUndo = null; };
const deleteHint = document.createElement('div');deleteHint.className='delete-hint';deleteHint.hidden=true;keyboard.append(deleteHint);
function deletePrompt(direction,button) {
  const key=button.getBoundingClientRect(),box=keyboard.getBoundingClientRect();
  deleteHint.style.right='8px';deleteHint.style.top=Math.max(2,key.top-box.top-38)+'px';
  deleteHint.style.background=direction<0?'#1ba88c':direction>0?'#ed4e59':'#586470';
  deleteHint.textContent=direction<0?'↓ 松手撤回':direction>0?'↑ 松手清空':'↑ 清空 · ↓ 撤回';deleteHint.hidden=false;
}
function clearFromGesture() {
  if(!editor.value)return;
  deletionUndo={text:editor.value,start:editor.selectionStart,end:editor.selectionEnd,composition,compositionStart};
  editor.value='';editor.setSelectionRange(0,0);composition='';compositionStart=-1;
  toast('已清空，下滑删除键可撤回');
}
function undoFromGesture() {
  if(!deletionUndo||editor.value){toast('没有可撤回的删除');return}
  const value=deletionUndo;deletionUndo=null;editor.value=value.text;editor.setSelectionRange(value.start,value.end);
  composition=value.composition;compositionStart=value.compositionStart;toast('已恢复删除的内容');
}
function finishDelete(cancelled=false) {
  clearTimeout(deleteGesture.timer);clearInterval(deleteGesture.repeat);
  if(!cancelled && deleteGesture.direction){if(deleteGesture.direction>0)clearFromGesture();else undoFromGesture();}
  if(!cancelled && !deleteGesture.used && deleteGesture.direction===0)press('delete');
  window.suppressDeleteClick=true;
  const button=deleteGesture.button,id=deleteGesture.id;deleteGesture.id=null;deleteGesture.button=null;
  window.deleteSwipeActive=false;deleteHint.hidden=true;
  if(button&&button.hasPointerCapture(id))button.releasePointerCapture(id);
  renderCandidates();renderKeys();
}
grid.addEventListener('pointerdown',event=>{
  const button=event.target.closest('[data-action="delete"]');if(!button||!event.isPrimary)return;
  deleteGesture.id=event.pointerId;deleteGesture.button=button;deleteGesture.startY=event.clientY;deleteGesture.direction=0;deleteGesture.used=false;
  window.deleteSwipeActive=true;window.suppressDeleteClick=false;button.setPointerCapture(event.pointerId);
  deleteGesture.timer=setTimeout(()=>{deleteGesture.used=true;press('delete');deleteGesture.repeat=setInterval(()=>press('delete'),65)},350);
});
grid.addEventListener('pointermove',event=>{
  if(event.pointerId!==deleteGesture.id)return;
  const y=event.clientY-deleteGesture.startY;deleteGesture.direction=y < -24?1:y>24?-1:0;
  if(Math.abs(y)>12){deleteGesture.used=true;clearTimeout(deleteGesture.timer);clearInterval(deleteGesture.repeat);deletePrompt(deleteGesture.direction,deleteGesture.button);}
});
grid.addEventListener('pointerup',event=>{if(event.pointerId===deleteGesture.id)finishDelete()});
grid.addEventListener('pointercancel',event=>{if(event.pointerId===deleteGesture.id)finishDelete(true)});
window.addEventListener('blur',()=>{if(deleteGesture.id!==null)finishDelete(true)});
