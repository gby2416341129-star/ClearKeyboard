const root = document.documentElement;
const keyboard = document.getElementById('keyboard');
const grid = document.getElementById('key-grid');
const editor = document.getElementById('editor');
const panel = document.getElementById('panel');
let page = 'letters', language = 'zh', shift = false, caps = false, lastShift = 0;
let composition = '', hand = 'full', currentCandidates = [], panelType = '', clips = [];

const paths = {
  shift: '<path d="M12 3 3 12h5v8h8v-8h5L12 3Z"/>',
  capslock: '<path d="M12 2 3 11h5v6h8v-6h5L12 2Z"/><path d="M8 21h8"/>',
  delete: '<path d="M9 5h11a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H9l-7-7 7-7Z"/><path d="m12 9 6 6m0-6-6 6"/>',
  globe: '<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="3.8" ry="9"/><path d="M3 12h18M5.2 6.5h13.6M5.2 17.5h13.6"/>',
  clipboard: '<rect x="6" y="5" width="14" height="17" rx="2.5"/><rect x="9" y="2" width="8" height="6" rx="2"/><path d="M6 18H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2M10 12h6M10 16h6"/>',
  emoji: '<circle cx="12" cy="12" r="9"/><path d="M8 14.2c1.5 3 6.5 3 8 0"/><circle cx="8.5" cy="9" r=".7" fill="currentColor" stroke="none"/><circle cx="15.5" cy="9" r=".7" fill="currentColor" stroke="none"/>',
  keyboard: '<rect x="2" y="5" width="20" height="14" rx="3"/><path d="M6 9h.01M10 9h.01M14 9h.01M18 9h.01M6 12h.01M10 12h.01M14 12h.01M18 12h.01M8 16h8"/>',
  appearance: '<path d="M3 6h4m4 0h10M3 12h10m4 0h4M3 18h4m4 0h10"/><circle cx="9" cy="6" r="2"/><circle cx="15" cy="12" r="2"/><circle cx="9" cy="18" r="2"/>',
  drop: '<path d="M12 2.5c-2.5 4-7 7.8-7 12a7 7 0 0 0 14 0c0-4.2-4.5-8-7-12Z"/><path d="M8.5 14.8a3.8 3.8 0 0 0 3.5 3.8"/>',
  restore: '<path d="M3 8h17M7 4 3 8l4 4m14 4H4m13-4 4 4-4 4"/>',
  close: '<circle cx="12" cy="12" r="9"/><path d="m9 9 6 6m0-6-6 6"/>',
  arrow: '<path d="M6 18 18 6M7 6h11v11"/>',
  chevron: '<path d="m6 9 6 6 6-6"/>'
};
function icon(name) {
  return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' + paths[name] + '</svg>';
}
const sample = {ni:['你','呢','泥'],nihao:['你好','你好吗'],hao:['好','号','浩'],xie:['谢','些','写'],xiexie:['谢谢','谢谢你'],wo:['我','握','窝'],women:['我们'],woaini:['我爱你'],shi:['是','时','事','十'],zhong:['中','种','重'],zhongguo:['中国'],zhongwen:['中文'],yingwen:['英文'],jin:['今','金','近'],jintian:['今天'],mingtian:['明天'],shurufa:['输入法'],liuchang:['流畅'],yetaiboli:['液态玻璃'],wei:['为','位','未'],weixin:['微信'],jian:['见','间','件'],jiantieban:['剪贴板'],nh:['你好'],wm:['我们'],srf:['输入法'],h:['好','和','会'],n:['你','能','那']};
const englishWords = ['hello','help','here','hey','home','hope','world','work','would','wonderful','keyboard','clear','beautiful','good','great','thanks','tomorrow','today','please','inspiration'];
const accents = {jade:['#298a70','青瓷'],ocean:['#3370b8','海盐'],rose:['#af5278','蔷薇'],graphite:['#646e7a','石墨']};

function toast(text) {
  const view = document.getElementById('toast'); view.textContent = text; view.classList.add('visible');
  clearTimeout(toast.timer); toast.timer = setTimeout(() => view.classList.remove('visible'), 2600);
}
function insert(text) {
  const start = editor.selectionStart, end = editor.selectionEnd;
  editor.value = editor.value.slice(0,start) + text + editor.value.slice(end);
  editor.setSelectionRange(start + text.length, start + text.length);
}
function getCandidates() {
  if (language === 'zh') {
    if (!composition) return [];
    if (sample[composition]) return sample[composition];
    return Object.entries(sample).filter(([key]) => key.startsWith(composition)).flatMap(([,value]) => value).filter((value,i,all) => all.indexOf(value) === i).slice(0,8);
  }
  const word = editor.value.slice(0,editor.selectionStart).match(/[a-zA-Z]+$/)?.[0] || '';
  return word ? englishWords.filter(value => value.startsWith(word.toLowerCase()) && value !== word.toLowerCase()).slice(0,6) : [];
}
function renderCandidates() {
  currentCandidates = getCandidates(); keyboard.classList.toggle('composing', !!composition);
  document.getElementById('spelling').textContent = composition;
  const container = document.getElementById('candidates'); container.replaceChildren();
  if (spaceGesture.active || !currentCandidates.length) {
    const hint = document.createElement('span'); hint.className = 'candidate-hint';
    hint.textContent = spaceGesture.active ? '左右滑动，移动光标' : composition ? '示例候选 · ' + composition : '离线就绪 · ' + (language === 'zh' ? '中文拼音' : 'English');
    container.append(hint); return;
  }
  currentCandidates.forEach(text => {
    const button = document.createElement('button'); button.className = 'candidate'; button.textContent = text;
    button.addEventListener('click', () => choose(text)); container.append(button);
  });
}
function choose(text) {
  if (language === 'zh') { insert(text); composition = ''; }
  else {
    const word = editor.value.slice(0,editor.selectionStart).match(/[a-zA-Z]+$/)?.[0] || '';
    editor.setSelectionRange(editor.selectionStart - word.length, editor.selectionStart);
    insert((word[0] === word[0]?.toUpperCase() ? text[0].toUpperCase() + text.slice(1) : text) + ' ');
  }
  renderCandidates(); renderKeys();
}
function commit() { if (composition) { insert(currentCandidates[0] || composition); composition = ''; } }
function key(label, action = label, units = 1, utility = false) { return {label,action,units,utility}; }
function rows() {
  let result;
  if (page === 'letters') {
    const letters = value => Array.from(value).map(char => key(shift ? char.toUpperCase() : char, char));
    result = [letters('qwertyuiop'),letters('asdfghjkl'),[key('Shift','shift',1.5,true),...letters('zxcvbnm'),key('删除','delete',1.5,true)]];
  } else {
    result = [(page === 'numbers' ? Array.from('1234567890') : ['[',']','{','}','#','%','^','*','+','=']).map(char => key(char)),
      (page === 'numbers' ? ['-','/',':',';','(',')','$','&','@','"'] : ['_','\\','|','~','<','>','€','£','¥','•']).map(char => key(char)),
      [key(page === 'numbers' ? '#+=' : '123',page === 'numbers' ? 'symbols' : 'numbers',1.5,true),...['.',',','?','!',"'"].map(char => key(char,char,1.4)),key('删除','delete',1.5,true)]];
  }
  return [...result,[key(page === 'letters' ? '123' : 'ABC',page === 'letters' ? 'numbers' : 'letters',1.25,true),key('切换语言','globe',1.15,true),key(language === 'zh' ? '空格' : 'space','space',5.2),key(composition ? '确认' : '换行','enter',2.4,true)]];
}

const metricsContext = document.createElement('canvas').getContext('2d',{willReadFrequently:true});
const metricCache = new Map();
function alignKeyLegends() {
  grid.querySelectorAll('.key-legend').forEach(legend => {
    const style = getComputedStyle(legend), font = style.fontWeight + ' ' + style.fontSize + ' ' + style.fontFamily;
    const identity = font + '|' + legend.textContent;
    let offset = metricCache.get(identity);
    if (!offset) {
      metricsContext.font = font; metricsContext.textBaseline = 'alphabetic';
      const m = metricsContext.measureText(legend.textContent);
      // Raster bounds account for the font hinting that vector ascent/descent metrics omit.
      metricsContext.clearRect(0,0,300,150); metricsContext.fillStyle = '#000';
      metricsContext.fillText(legend.textContent,16,48);
      const left = Math.max(0,Math.floor(16 - m.actualBoundingBoxLeft) - 3);
      const top = Math.max(0,Math.floor(48 - m.actualBoundingBoxAscent) - 3);
      const width = Math.min(300 - left,Math.ceil(m.actualBoundingBoxLeft + m.actualBoundingBoxRight) + 7);
      const height = Math.min(150 - top,Math.ceil(m.actualBoundingBoxAscent + m.actualBoundingBoxDescent) + 7);
      const pixels = metricsContext.getImageData(left,top,width,height).data;
      let minX = width, maxX = 0, minY = height, maxY = 0;
      for (let y=0;y<height;y++) for (let x=0;x<width;x++) if (pixels[(y*width+x)*4+3]>=128) {
        minX=Math.min(minX,x); maxX=Math.max(maxX,x); minY=Math.min(minY,y); maxY=Math.max(maxY,y);
      }
      offset = [16 - left - (minX + maxX + 1)/2,48 - top - (minY + maxY + 1)/2];
      metricCache.set(identity,offset);
    }
    const box = legend.parentElement.getBoundingClientRect();
    legend.setAttribute('x',String(box.width/2 + offset[0]));
    legend.setAttribute('y',String(box.height/2 + offset[1]));
  });
}
function renderKeys() {
  if (spaceGesture.active) return;
  grid.replaceChildren();
  rows().forEach((items,index) => {
    const row = document.createElement('div'); row.className = 'key-row' + (page === 'letters' && index === 1 ? ' inset' : '');
    items.forEach(item => {
      const button = document.createElement('button');
      const graphic = ['shift','delete','globe'].includes(item.action);
      button.className = 'key' + (item.utility ? ' utility' : '') + (!graphic && item.label.length > 1 ? ' small' : '') + (item.action === 'enter' ? ' enter' : '') + (item.action === 'shift' && shift ? ' active' : '');
      button.style.flex = item.units; button.dataset.action = item.action;
      button.setAttribute('aria-label',({shift:'Shift',delete:'删除',globe:'切换语言',space:'空格，按住并滑动以移动光标',enter:'回车'})[item.action] || item.label);
      const face = document.createElement('span'); face.className = 'key-face';
      if (graphic) face.innerHTML = icon(item.action === 'shift' && caps ? 'capslock' : item.action);
      else {
        const svg = document.createElementNS('http://www.w3.org/2000/svg','svg');
        svg.classList.add('key-text'); svg.setAttribute('aria-hidden','true'); svg.setAttribute('focusable','false');
        const legend = document.createElementNS('http://www.w3.org/2000/svg','text');
        legend.classList.add('key-legend'); legend.textContent = item.label; svg.append(legend); face.append(svg);
      }
      button.append(face);
      button.addEventListener('pointerdown', event => {
        event.preventDefault(); const bounds = button.getBoundingClientRect();
        button.style.setProperty('--press-x',((event.clientX - bounds.left)/bounds.width*100) + '%');
        button.style.setProperty('--press-y',((event.clientY - bounds.top)/bounds.height*100) + '%');
      });
      button.addEventListener('click', () => {
        if (item.action === 'space' && spaceGesture.suppressClick) { spaceGesture.suppressClick = false; return; }
        if (!spaceGesture.active) press(item.action);
      });
      row.append(button);
    });
    grid.append(row);
  });
  grid.className = 'key-grid ' + (hand === 'full' ? '' : hand);
  document.querySelector('.restore').className = 'restore ' + (hand === 'full' ? '' : hand);
  alignKeyLegends();
}
function press(action) {
  if (action === 'shift') { const now = Date.now(); caps = now - lastShift < 300; shift = caps ? true : !shift; lastShift = now; }
  else if (['letters','numbers','symbols'].includes(action)) page = action;
  else if (action === 'delete') {
    if (composition) composition = composition.slice(0,-1);
    else if (editor.selectionStart !== editor.selectionEnd) insert('');
    else if (editor.selectionStart) {
      const bounds = graphemeBoundaries(editor.value), pos = editor.selectionStart;
      const previous = bounds.filter(value => value < pos).pop() ?? 0;
      editor.setSelectionRange(previous,pos); insert('');
    }
  } else if (action === 'globe') switchLanguage();
  else if (action === 'space' || action === 'enter') { if (composition) commit(); else insert(action === 'space' ? ' ' : '\n'); }
  else if (language === 'zh' && page === 'letters' && !shift && /^[a-z]$/.test(action)) composition += action;
  else {
    commit(); const punctuation = {',':'，','.':'。','?':'？','!':'！'};
    insert(shift && page === 'letters' ? action.toUpperCase() : language === 'zh' ? (punctuation[action] || action) : action);
    if (!caps) shift = false;
  }
  renderCandidates(); renderKeys();
}

const segmenter = new Intl.Segmenter('zh',{granularity:'grapheme'});
function graphemeBoundaries(text) { return [...Array.from(segmenter.segment(text),part => part.index),text.length]; }
const spaceGesture = {active:false, pointerId:null, startX:0, startY:0, lastX:0, timer:null, button:null, suppressClick:false, boundaries:[]};
function beginSpaceTrackpad() {
  spaceGesture.active = true; spaceGesture.suppressClick = true;
  commit(); spaceGesture.boundaries = graphemeBoundaries(editor.value);
  keyboard.classList.add('cursor-mode'); editor.focus({preventScroll:true}); renderCandidates();
}
function moveCaret(steps) {
  const boundaries = spaceGesture.boundaries;
  let position = steps < 0 ? editor.selectionStart : editor.selectionEnd;
  let index = boundaries.findIndex(value => value >= position);
  if (index < 0) index = boundaries.length - 1;
  index = Math.max(0,Math.min(boundaries.length - 1,index + steps));
  editor.setSelectionRange(boundaries[index],boundaries[index]);
}
function finishSpaceTrackpad(cancelled = false) {
  clearTimeout(spaceGesture.timer);
  const wasActive = spaceGesture.active, button = spaceGesture.button, id = spaceGesture.pointerId;
  spaceGesture.active = false; spaceGesture.pointerId = null; spaceGesture.button = null;
  if (cancelled || wasActive) spaceGesture.suppressClick = true;
  if (button && id !== null && button.hasPointerCapture(id)) button.releasePointerCapture(id);
  keyboard.classList.remove('cursor-mode');
  if (wasActive) { renderCandidates(); renderKeys(); }
}
grid.addEventListener('pointerdown', event => {
  const button = event.target.closest('[data-action="space"]');
  if (!button || spaceGesture.pointerId !== null || !event.isPrimary) return;
  spaceGesture.suppressClick = false; spaceGesture.pointerId = event.pointerId; spaceGesture.button = button;
  spaceGesture.startX = spaceGesture.lastX = event.clientX; spaceGesture.startY = event.clientY;
  button.setPointerCapture(event.pointerId);
  spaceGesture.timer = setTimeout(beginSpaceTrackpad,350);
});
grid.addEventListener('pointermove', event => {
  if (event.pointerId !== spaceGesture.pointerId) return;
  if (!spaceGesture.active) {
    if (Math.hypot(event.clientX - spaceGesture.startX,event.clientY - spaceGesture.startY) > 14) { clearTimeout(spaceGesture.timer); spaceGesture.suppressClick = true; }
    return;
  }
  const delta = Math.trunc((event.clientX - spaceGesture.lastX)/9);
  if (delta) { moveCaret(delta); spaceGesture.lastX += delta*9; }
});
grid.addEventListener('pointerup', event => { if (event.pointerId === spaceGesture.pointerId) finishSpaceTrackpad(); });
grid.addEventListener('pointercancel', event => { if (event.pointerId === spaceGesture.pointerId) finishSpaceTrackpad(true); });
grid.addEventListener('lostpointercapture', event => { if (event.pointerId === spaceGesture.pointerId) finishSpaceTrackpad(true); });
window.addEventListener('blur',() => finishSpaceTrackpad(true));
document.addEventListener('visibilitychange',() => { if (document.hidden) finishSpaceTrackpad(true); });
editor.inputMode = 'none';

function switchLanguage() { commit(); language = language === 'zh' ? 'en' : 'zh'; page = 'letters'; shift = false; document.querySelector('.tool.lang').textContent = language === 'zh' ? '中 / EN' : 'EN / 中'; }
function setHand(value) { finishSpaceTrackpad(true); hand = value; document.querySelectorAll('[data-hand]').forEach(button => button.setAttribute('aria-pressed',String(button.dataset.hand === value))); renderKeys(); }
function closePanel() { panel.classList.remove('open'); panelType = ''; }
function openPanel(type) {
  if (panelType === type) { closePanel(); return; }
  panelType = type; panel.replaceChildren(); panel.classList.add('open');
  const header = document.createElement('div'); header.className = 'panel-header';
  const title = document.createElement('strong'); title.textContent = ({clipboard:'剪贴板',emoji:'表情',onehand:'单手模式',appearance:'外观'})[type];
  const done = document.createElement('button'); done.textContent = '完成'; done.onclick = closePanel; header.append(title,done); panel.append(header);
  const note = document.createElement('p');
  if (type === 'emoji') {
    [['😀','🥹','🥰','😎','🥳','😭','🤔','🫶'],['👍','🙏','❤️','✨','🎉','🌙','☕️','🌸']].forEach(group => {
      const row = document.createElement('div'); row.className = 'emoji-row';
      group.forEach(text => { const button = document.createElement('button'); button.textContent = text; button.onclick = () => { commit(); insert(text); renderCandidates(); }; row.append(button); }); panel.append(row);
    });
    note.textContent = '文字表情直接输入。原生版本另有颜文字和可复制的文字贴纸。';
  } else if (type === 'clipboard') {
    const add = document.createElement('button'); add.className = 'clip'; add.textContent = '＋ 添加示例内容';
    add.onclick = () => { clips.unshift('为你留一份灵感。'); panelType = ''; openPanel('clipboard'); }; panel.append(add);
    clips.forEach(text => { const button = document.createElement('button'); button.className = 'clip'; button.textContent = text; button.onclick = () => { commit(); insert(text); closePanel(); renderCandidates(); }; panel.append(button); });
    note.textContent = '预览只保存示例。原生版本由用户主动读取系统剪贴板。';
  } else if (type === 'onehand') {
    const segment = document.createElement('div'); segment.className = 'segments';
    [['full','标准'],['left','左手'],['right','右手']].forEach(([value,label]) => { const button = document.createElement('button'); button.textContent = label; button.setAttribute('aria-pressed',String(value === hand)); button.onclick = () => { setHand(value); closePanel(); }; segment.append(button); }); panel.append(segment);
    note.textContent = '缩窄整体宽度。按住空格，再左右滑动可移动光标。';
  } else {
    const segment = document.createElement('div'); segment.className = 'segments';
    [['clear','清透'],['mist','柔雾'],['solid','纯净']].forEach(([value,label]) => { const button = document.createElement('button'); button.textContent = label; button.onclick = () => setGlass(value); segment.append(button); }); panel.append(segment);
    note.textContent = '左侧提供任意颜色、HEX 色值和浓度调节。原生 iOS 26 使用系统 Liquid Glass。';
  }
  panel.append(note);
}
function setGlass(value) {
  keyboard.classList.remove('mist','solid'); if (value !== 'clear') keyboard.classList.add(value);
  document.querySelectorAll('[data-glass]').forEach(button => button.setAttribute('aria-pressed',String(button.dataset.glass === value)));
  document.getElementById('phone-glass').textContent = ({clear:'清透',mist:'柔雾',solid:'纯净'})[value];
}
function setColor(value, preset = null) {
  let hex = value.trim().replace(/^#/,''); if (/^[0-9a-f]{3}$/i.test(hex)) hex = Array.from(hex,char => char + char).join('');
  const input = document.getElementById('hex-color');
  if (!/^[0-9a-f]{6}$/i.test(hex)) { input.setAttribute('aria-invalid','true'); return false; }
  hex = '#' + hex.toUpperCase();
  const channels = [1,3,5].map(start => parseInt(hex.slice(start,start+2),16));
  const luma = channels[0]*.2126 + channels[1]*.7152 + channels[2]*.0722;
  const ink = luma > 140 ? 'rgb(' + channels.map(channel => Math.round(channel*107/luma)).join(',') + ')' : hex;
  root.style.setProperty('--rgb',channels.join(',')); root.style.setProperty('--accent',hex); root.style.setProperty('--ink-accent',ink);
  root.style.setProperty('--on-accent',luma > 153 ? '#172a21' : '#ffffff');
  document.getElementById('custom-color').value = hex; input.value = hex; input.setAttribute('aria-invalid','false');
  const name = preset ? accents[preset][1] : hex;
  document.getElementById('accent-title').textContent = name; document.getElementById('phone-accent').textContent = name;
  document.querySelectorAll('[data-accent]').forEach(button => button.setAttribute('aria-pressed',String(button.dataset.accent === preset)));
  return true;
}

function installRefraction() {
  const canvas = document.createElement('canvas'); canvas.width = canvas.height = 128;
  const context = canvas.getContext('2d'), image = context.createImageData(128,128);
  for (let y=0; y<128; y++) for (let x=0; x<128; x++) {
    const index = (y*128+x)*4, dx = (x+.5)/64-1, dy = (y+.5)/64-1;
    image.data[index] = 128 + Math.sign(dx)*Math.pow(Math.abs(dx),7)*116;
    image.data[index+1] = 128 + Math.sign(dy)*Math.pow(Math.abs(dy),7)*116;
    image.data[index+2] = 128; image.data[index+3] = 255;
  }
  context.putImageData(image,0,0);
  const svg = document.createElementNS('http://www.w3.org/2000/svg','svg'); svg.setAttribute('width','0'); svg.setAttribute('height','0');
  svg.style.position = 'absolute'; svg.setAttribute('aria-hidden','true');
  svg.innerHTML = '<defs><filter id="key-refraction" x="0%" y="0%" width="100%" height="100%" color-interpolation-filters="sRGB"><feImage href="'+canvas.toDataURL()+'" x="0" y="0" width="100%" height="100%" preserveAspectRatio="none" result="displacement"/><feDisplacementMap in="SourceGraphic" in2="displacement" scale="10" xChannelSelector="R" yChannelSelector="G"/></filter></defs>';
  document.body.append(svg);
}
document.querySelectorAll('[data-tool]').forEach(button => {
  if (button.dataset.tool !== 'language') button.innerHTML = icon(button.dataset.tool === 'onehand' ? 'keyboard' : button.dataset.tool);
  button.onclick = () => { if (button.dataset.tool === 'language') { closePanel(); switchLanguage(); renderCandidates(); renderKeys(); } else openPanel(button.dataset.tool); };
});
document.querySelector('.drop').innerHTML = icon('drop');
document.querySelector('.restore').innerHTML = icon('restore'); document.querySelector('.restore').onclick = () => setHand('full');
document.querySelector('.clear-spelling').innerHTML = icon('close'); document.querySelector('.clear-spelling').onclick = () => { composition = ''; renderCandidates(); renderKeys(); };
document.querySelector('.enable span').innerHTML = icon('arrow');
document.querySelectorAll('[data-tab]').forEach(button => {
  button.querySelector('b').innerHTML = icon(({home:'drop',custom:'appearance',input:'keyboard'})[button.dataset.tab]);
  button.onclick = () => { const name = button.dataset.tab; document.querySelectorAll('[data-tab]').forEach(value => value.setAttribute('aria-selected',String(value === button))); document.querySelectorAll('.app-page').forEach(value => value.classList.remove('visible')); if (name !== 'home') document.getElementById(name+'-page').classList.add('visible'); };
});
document.querySelectorAll('[data-glass]').forEach(button => button.onclick = () => setGlass(button.dataset.glass));
document.querySelectorAll('[data-hand]').forEach(button => button.onclick = () => setHand(button.dataset.hand));
document.querySelectorAll('[data-accent]').forEach(button => button.onclick = () => setColor(accents[button.dataset.accent][0],button.dataset.accent));
document.getElementById('custom-color').addEventListener('input',event => setColor(event.target.value));
document.getElementById('hex-color').addEventListener('keydown',event => { if (event.key === 'Enter') setColor(event.target.value); });
document.getElementById('apply-color').onclick = () => setColor(document.getElementById('hex-color').value);
document.getElementById('opacity').oninput = event => {
  root.style.setProperty('--opacity',event.target.value/100); document.getElementById('opacity-value').textContent = event.target.value + '%';
  document.querySelector('#key-refraction feDisplacementMap').setAttribute('scale',String(14-event.target.value*.08));
};
document.getElementById('enable').onclick = () => { document.getElementById('setup').classList.add('open'); document.getElementById('dim').style.display = 'block'; };
function closeSetup() { document.getElementById('setup').classList.remove('open'); document.getElementById('dim').style.display = 'none'; }
document.getElementById('setup-done').onclick = closeSetup; document.getElementById('dim').onclick = closeSetup;
editor.addEventListener('input',() => { composition = ''; renderCandidates(); });
window.addEventListener('resize',() => requestAnimationFrame(alignKeyLegends));
document.fonts.ready.then(alignKeyLegends);
installRefraction(); editor.setSelectionRange(editor.value.length,editor.value.length); renderKeys(); renderCandidates();
