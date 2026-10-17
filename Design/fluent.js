function fluentIcon(name) {
  const objects = {
    brand: '<path d="M16 1C22 9 29 13 29 20C29 35 3 35 3 20C3 13 10 9 16 1Z" fill="url(#water)"/><path d="M3 20C7 10 25 13 25 24C21 35 3 33 3 20Z" fill="url(#wave)"/><path d="m11 14-3 6" stroke="#fff" stroke-opacity=".8" stroke-width="2.1" stroke-linecap="round"/>',
    clipboard: '<rect x="5" y="4" width="20" height="25" rx="4" fill="url(#blue)"/><rect x="9" y="7" width="19" height="24" rx="3" fill="url(#paper)"/><rect x="10" y="2" width="10" height="6" rx="2" fill="url(#wave)"/><path d="M13 13h10m-10 5h10m-10 5h10" stroke="#528fc8" stroke-width="1.8" stroke-linecap="round"/>',
    emoji: '<circle cx="16" cy="16" r="14" fill="url(#gold)"/><ellipse cx="10.5" cy="13" rx="1.5" ry="2" fill="#70401e"/><ellipse cx="21.5" cy="13" rx="1.5" ry="2" fill="#70401e"/><path d="M9 20q7 10 14 0" stroke="#ac561e" stroke-width="2.2" stroke-linecap="round" fill="none"/>',
    keyboard: '<rect x="1" y="7" width="30" height="21" rx="5" fill="url(#steel)"/><rect x="3" y="9" width="26" height="15" rx="3" fill="url(#paper)"/>' + Array.from({length:12},(_,i)=>'<rect x="'+(5+i%6*3.8)+'" y="'+(11+Math.floor(i/6)*4)+'" width="2.7" height="2.7" rx=".8" fill="#6c98c3"/>').join('') + '<rect x="10" y="20" width="12" height="2.5" rx=".8" fill="#409dc6"/>',
    language: '<rect x="2" y="3" width="19" height="23" rx="4" fill="url(#blue)"/><rect x="12" y="10" width="18" height="21" rx="4" fill="url(#purple)"/><text x="5" y="18" font-size="12" font-family="sans-serif" fill="white">文</text><text x="17" y="26" font-size="14" font-family="sans-serif" font-weight="600" fill="white">A</text>',
    appearance: '<rect x="3" y="4" width="24" height="24" rx="7" fill="url(#paper)"/><circle cx="11.5" cy="11.5" r="3.5" fill="url(#blue)"/><circle cx="20.5" cy="11.5" r="3.5" fill="url(#pink)"/><circle cx="11.5" cy="20.5" r="3.5" fill="url(#gold)"/><g transform="translate(22 21) rotate(36)"><rect x="-2" y="-9" width="4" height="16" rx="1.5" fill="url(#blue)"/><rect x="-3" y="4" width="6" height="7" rx="2" fill="#b88b64"/></g>',
    toolbar: '<rect x="3" y="3" width="11" height="11" rx="3" fill="url(#blue)"/><rect x="18" y="3" width="11" height="11" rx="3" fill="url(#purple)"/><rect x="3" y="18" width="11" height="11" rx="3" fill="url(#wave)"/><rect x="18" y="18" width="11" height="11" rx="3" fill="url(#gold)"/>'
  };
  const body = objects[name]; if (!body) return null;
  const palettes = {water:['#69e8e3','#1767ce'],wave:['#b9f8ee','#31bdb4'],blue:['#80d4ff','#3683d8'],paper:['#f6fcff','#bac8dc'],gold:['#ffe788','#f4a325'],purple:['#c3a6fa','#7956d1'],pink:['#ffa8d0','#da4d97'],steel:['#86bee8','#4264a8']};
  const prefix = 'fluent-'+name+'-';
  const defs = Object.entries(palettes).map(([key,colors])=>'<linearGradient id="'+prefix+key+'" x2="1" y2="1"><stop stop-color="'+colors[0]+'"/><stop offset="1" stop-color="'+colors[1]+'"/></linearGradient>').join('');
  return '<svg viewBox="0 0 32 32" fill="none" stroke="none" aria-hidden="true" focusable="false"><defs>'+defs+'</defs>'+body.replace(/url\(#(\w+)\)/g,(_,key)=>'url(#'+prefix+key+')')+'</svg>';
}

// Design-preview arithmetic; the shipped app uses the separately tested Swift parser.
function previewCalculation(context) {
  const match = context.match(/[0-9.+\-xX×*/÷() ]+$/); if (!match) return null;
  const expression = match[0].trim();
  if (!/[+\-xX×*/÷]/.test(expression) || expression.length >= 128) return null;
  const input = expression.replace(/[xX×]/g,'*').replace(/÷/g,'/').replace(/\s/g,'');
  let at = 0, operations = 0, depth = 0;
  function take(chars) { const char=input[at];if(char && chars.includes(char)){at++;return char}return null; }
  function factor(){const sign=take('+-');if(sign)return(sign==='-'?-1:1)*factor();if(take('(')){if(++depth>8)throw 0;const result=sum();if(!take(')'))throw 0;depth--;return result}const start=at;while(at<input.length && /[0-9.]/.test(input[at]))at++;if(at===start)throw 0;const result=Number(input.slice(start,at));if(!Number.isFinite(result))throw 0;return result;}
  function term(){let result=factor(),op;while((op=take('*/'))){const rhs=factor();if(op==='/'&&rhs===0)throw 0;operations++;result=op==='*'?result*rhs:result/rhs;}return result;}
  function sum(){let result=term(),op;while((op=take('+-'))){const rhs=term();operations++;result=op==='+'?result+rhs:result-rhs;}return result;}
  try {const result=sum();if(at!==input.length||!operations||!Number.isFinite(result)||Math.abs(result)>1e15)return null;const value=String(Number(result.toFixed(10)));return{expression,candidates:[value,expression+'='+value]}}catch{return null}
}
