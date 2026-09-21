(() => {
  const $ = id => document.getElementById(id);
  const names = ['旅行', '工作', '生活'];
  const films = ['海边日落', '山路行车', '城市夜景', '林间步道', '产品演示', '访谈片段', '工作记录', '发布会剪辑', '周末散步', '厨房记录', '雨后街道', '家庭聚会'];
  const initialStates = () => [...Array(10).fill('pending'), 'missing', 'missing'];
  let mode='mixed', states=initialStates(), view=new URLSearchParams(location.search).get('entry')==='scan'?'scan':'unavailable';
  let timer, queue=[], processed=0, recovered=0, running=false, message='', currentFile=null;
  let authorized=new Set();
  const storageKey='filefacet-folder-recovery-draft-v3';
  const eligible = () => states.map((s,i)=>s==='pending'?i:-1).filter(i=>i>=0);
  function save(){try{sessionStorage.setItem(storageKey,JSON.stringify({mode,states,authorized:[...authorized]}));}catch{}}
  function render(){
    const left=states.filter(s=>s!=='ok').length;
    $('unavailableCount').textContent=left+2;
    $('pageTitle').textContent=view==='scan'?'待导入视频':view==='all'?'所有视频':'不可用视频';
    $('pageDetail').textContent=view==='scan'?'3 个新视频，等待选择导入':view==='all'?`${14-states.filter(s=>s==='missing').length} 个视频`:`${left} 个无法访问 · 2 个离线`;
    $('openRecovery').hidden=view!=='unavailable'||!eligible().length||running;
    $('scanNotice').hidden=view!=='scan'||!eligible().length||running;
    $('scanNotice').firstElementChild.textContent=`${eligible().length} 个已有视频的访问需要恢复。`;
    $('scopeSummary').textContent=running?'正在核对本次参与恢复的视频。':eligible().length?`${eligible().length} 个视频可尝试恢复。确认访问后核对原文件。`:'当前没有可一键恢复的视频。';
    $('feedback').textContent=message;
    $('feedback').classList.toggle('ok', message.startsWith('已重新连接') || (recovered>0 && !message.includes('未恢复') && !message.includes('停止')));
    $('dismissFeedback').hidden=!message;
    $('progressArea').hidden=!running;
    if(running){$('progress').max=queue.length;$('progress').value=processed;$('progressLabel').textContent=`正在恢复 · 已核对 ${processed} / ${queue.length} 个`;}
    ['navAll','navUnavailable','navScan'].forEach((id,i)=>$(id).classList.toggle('selected',['all','unavailable','scan'][i]===view));
    const list=view==='scan'?['新的海边片段','产品补录','周末骑行'].map(name=>({name,status:'待导入',reason:''})):films.flatMap((name,i)=>((view==='unavailable'&&states[i]==='ok')||(view==='all'&&states[i]==='missing'))?[]:[{name,id:i,status:states[i]==='ok'?'可用':'无法访问',reason:states[i]==='missing'?'原位置未找到':states[i]==='different'?'原位置文件内容不一致':'',action:['missing','different'].includes(states[i])}]).concat([{name:'旧城漫步',status:'离线',reason:'Archive SSD'},{name:'山间露营',status:'离线',reason:'Archive SSD'}]);
    $('navAll').querySelector('span').textContent=14-states.filter(s=>s==='missing').length;
    $('cards').innerHTML=list.map(item=>`<article class="card"><div class="thumb" aria-hidden="true">▷</div><div class="card-copy"><strong>${item.name}.mov</strong><span class="${item.status==='可用'?'ok':''}">${item.status}${item.reason?' · '+item.reason:''}</span>${item.action?`<button data-file="${item.id}" ${running?'disabled':''}>重新定位…</button>`:''}</div></article>`).join('');
  }
  function finish(stopped=false){
    clearTimeout(timer);running=false;if($('picker').open)$('picker').close();
    const failed=processed-recovered, remaining=queue.length-processed;
    message=stopped?`已停止：恢复 ${recovered} 个，${failed} 个未恢复，${remaining} 个未检查。`:queue.length===recovered?`已恢复全部 ${recovered} 个视频。`:`已恢复 ${recovered} 个，${queue.length-recovered} 个未恢复。`;
    if(!stopped&&mode==='denied')message+=' 文件夹仍无法读取，可稍后重试。';
    save();render();
  }
  function step(){
    if(!running)return;
    if(processed===queue.length){finish();return;}
    const i=queue[processed],group=Math.floor(i/4);
    if(!authorized.has(group)){
      $('authorizationFolder').textContent=names[group];
      $('authorizationPath').textContent=`个人文件 / 素材 / ${names[group]}`;
      const needed=[...new Set(queue.slice(processed).map(i=>Math.floor(i/4)))].filter(g=>!authorized.has(g)).length;
      $('authorizationDetail').textContent=`需要确认 ${needed} 个原文件夹的访问。请确认以下目录。`;
      $('picker').showModal();return;
    }
    timer=setTimeout(()=>{
      states[i]=mode==='denied'?'pending':mode==='mixed'&&i===7?'different':mode==='mixed'&&i===9?'missing':'ok';
      if(states[i]==='ok')recovered++;
      processed++;save();render();step();
    },650);
  }
  function start(){if(running)return;queue=eligible();if(!queue.length)return;processed=0;recovered=0;message='';running=true;render();step();}
  $('openRecovery').onclick=$('scanRecovery').onclick=start;
  $('confirmFolders').onclick=()=>{authorized.add(Math.floor(queue[processed]/4));$('picker').close();step();};
  $('cancelPicker').onclick=()=>finish(true);
  $('picker').addEventListener('cancel',e=>{e.preventDefault();finish(true);});
  $('stop').onclick=()=>finish(true);
  let fileStage='select', fileTimer, fileRevision=0, fileOutcome='exact', existingTarget=4;
  function fileSelection(){
    fileStage='select';
    $('fileTitle').textContent='重新定位原文件';
    $('fileDescription').textContent=`为“${films[currentFile]}.mov”选择原文件。`;
    $('selectedFile').textContent=films[currentFile]+'.mov';
    $('selectedFile').setAttribute('aria-pressed','true');
    $('fileSelection').hidden=false;
    ['difference','forceConnect','fileError','viewExisting','fileProgress'].forEach(id=>$(id).hidden=true);
    $('confirmFile').hidden=false;$('confirmFile').disabled=false;$('confirmFile').textContent='选择';
  }
  function closeFile(){clearTimeout(fileTimer);fileRevision++;$('filePicker').close();}
  $('cards').onclick=e=>{
    const button=e.target.closest('[data-file]');if(!button||running)return;
    currentFile=Number(button.dataset.file);existingTarget=currentFile===4?0:4;fileOutcome=$('demoRelinkOutcome').value;
    fileSelection();$('filePicker').showModal();
  };
  $('selectedFile').onclick=()=>{
    const selected=$('selectedFile').getAttribute('aria-pressed')==='true';
    $('selectedFile').setAttribute('aria-pressed',String(!selected));$('confirmFile').disabled=selected;
  };
  function connectFile(){states[currentFile]='ok';message='已重新连接所选视频。';save();closeFile();render();}
  $('confirmFile').onclick=()=>{
    if(fileStage==='result'){fileSelection();return;}
    fileStage='checking';const revision=++fileRevision;
    $('fileTitle').textContent='正在核对所选文件';$('fileSelection').hidden=true;
    $('fileProgress').hidden=false;$('confirmFile').disabled=true;
    fileTimer=setTimeout(()=>{
      if(revision!==fileRevision)return;
      if(fileOutcome==='exact'){connectFile();return;}
      fileStage='result';$('fileProgress').hidden=true;$('confirmFile').disabled=false;
      $('confirmFile').textContent='重新选择';$('fileTitle').textContent='核对结果';$('fileDescription').textContent=`所选文件：${films[currentFile]}.mov`;
      if(['different','unknown'].includes(fileOutcome)){
        $('difference').hidden=$('forceConnect').hidden=false;
        $('differenceDetail').textContent=fileOutcome==='unknown'?'现有记录不足以确认所选文件与原文件一致，请重新选择，或自行确认是否连接。':'原记录：00:24 · 1920 × 1080；所选文件：00:18 · 1280 × 720。';
      }else{
        $('fileError').hidden=false;
        $('fileError').textContent=fileOutcome==='existing'?'所选文件已存在于 FileFacet，当前视频保持不变。':'无法完整读取所选文件，请检查文件后重试。';
        $('viewExisting').hidden=fileOutcome!=='existing';
      }
      $('confirmFile').focus();
    },1100);
  };
  $('forceConnect').onclick=connectFile;
  $('viewExisting').onclick=()=>{
    closeFile();view='all';message=`已定位到已有记录：${films[existingTarget]}.mov。`;render();
    const card=[...$('cards').children].find(card=>card.textContent.includes(films[existingTarget]));
    if(card){card.classList.add('highlighted');card.scrollIntoView({block:'nearest'});}
  };
  $('cancelFile').onclick=closeFile;
  $('filePicker').addEventListener('cancel',e=>{e.preventDefault();closeFile();});
  $('dismissFeedback').onclick=()=>{message='';render();};
  [['navAll','all'],['navUnavailable','unavailable'],['navScan','scan'],['demoScan','scan']].forEach(([id,next])=>$(id).onclick=()=>{view=next;message='';render();});

  document.querySelectorAll('[data-scenario]').forEach(button=>button.onclick=()=>{
    clearTimeout(fileTimer);fileRevision++;clearTimeout(timer);document.querySelectorAll('dialog[open]').forEach(d=>d.close());
    running=false;mode=button.dataset.scenario;states=mode==='none'?Array(12).fill('missing'):initialStates();authorized=new Set();message='';recovered=0;view='unavailable';save();render();
  });
  $('demoRestart').onclick=()=>{save();location.reload();};
  try{const saved=JSON.parse(sessionStorage.getItem(storageKey));if(saved&&['mixed','all','denied','none'].includes(saved.mode)&&Array.isArray(saved.states)&&saved.states.length===12&&saved.states.every(s=>['pending','ok','different','missing'].includes(s))){mode=saved.mode;states=saved.states;authorized=new Set((saved.authorized||[]).filter(g=>[0,1,2].includes(g)));}}catch{}
  render();
})();
