"""Exercise the actual HTTP server with isolated data, synthetic AD and driver packages."""
import base64, contextlib, http.cookiejar, json, os, pathlib, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request, uuid, zipfile
root=pathlib.Path(__file__).resolve().parents[1]
dotnet=os.environ.get('PD_WEB_DOTNET','dotnet')
powershell=os.environ.get('PD_WEB_POWERSHELL','powershell.exe' if os.name=='nt' else 'pwsh')
checks=0

def check(value, name):
    global checks
    if not value: raise AssertionError(name)
    checks+=1; print('PASS',name,flush=True)

with tempfile.TemporaryDirectory(prefix='pd-web-http-') as tmp:
    data=pathlib.Path(tmp); sock=socket.socket(); sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close(); base=f'http://localhost:{port}'
    env=os.environ.copy();env.update({'ASPNETCORE_ENVIRONMENT':'Development','PrintDeploy__DevelopmentMode':'true','PrintDeploy__Port':str(port),'PrintDeploy__DataDirectory':str(data/'server-data'),'PrintDeploy__PublicUrl':base,'PrintDeploy__PowerShellPath':powershell})
    output=open(data/'server.log','w',encoding='utf-8')
    process=subprocess.Popen([dotnet,str(root/'Server/bin/Debug/net10.0/PrintDeploy.Web.dll')],cwd=root/'Server',env=env,stdout=output,stderr=output)
    jar=http.cookiejar.CookieJar(); browser=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar));token='';revision=1
    def request(path,method='GET',body=None,auth=True,headers=None):
        h=dict(headers or {}); raw=body
        if isinstance(body,dict):raw=json.dumps(body).encode();h['Content-Type']='application/json'
        if method!='GET' and auth:h.update({'X-CSRF-Token':token,'If-Match':f'"{revision}"'})
        req=urllib.request.Request(base+path,data=raw,method=method,headers=h)
        try:
            with browser.open(req,timeout=80) as response:return response.status,response.read(),response.headers
        except urllib.error.HTTPError as error:return error.code,error.read(),error.headers
    def state():
        global revision
        status,body,_=request('/api/admin/state');check(status==200,'Administrator state is readable');value=json.loads(body);revision=value['Revision'];return value
    try:
        for _ in range(200):
            if process.poll() is not None: raise RuntimeError((data/'server.log').read_text())
            try:
                if request('/health')[0]==200:break
            except urllib.error.URLError:pass
            time.sleep(.1)
        else:raise RuntimeError('Server did not start')
        status,body,_=request('/');check(status==200 and b'PrintDeploy Web' in body,'Web UI is served')
        status,body,_=request('/api/admin/session');session=json.loads(body);token=session['CsrfToken'];check(status==200 and session['DevelopmentMode'],'Demo admin session issues CSRF token')
        value=state(); deployment=value['Settings']['DeploymentId']
        printer={'Id':str(uuid.uuid4()),'Name':'Global IPP','Kind':'IPP','Address':'ipp://192.0.2.55:631/ipp/print','PortNumber':631,'Location':'Synthetic office','Comment':'','Enabled':True,'AllComputers':True,'IncludeChildOus':True,'OrganizationalUnits':[],'Drivers':{}}
        check(request('/api/admin/printers/'+printer['Id'],'PUT',printer,auth=False)[0]==403,'Admin mutation without CSRF rejected')
        check(request('/api/admin/printers/'+printer['Id'],'PUT',printer)[0]==200,'Master printer created');value=state()
        scoped={**printer,'Id':str(uuid.uuid4()),'Name':'Workstation IPP','AllComputers':False,'OrganizationalUnits':['OU=Workstations,DC=example,DC=test']}
        check(request('/api/admin/printers/'+scoped['Id'],'PUT',scoped)[0]==200,'OU-scoped printer created');value=state()
        stale={**printer,'Name':'Stale overwrite'}
        status,_,_=request('/api/admin/printers/'+printer['Id'],'PUT',stale,auth=False,headers={'X-CSRF-Token':token,'If-Match':'"1"','Content-Type':'application/json'})
        check(status==409,'A stale revision cannot overwrite printer state');value=state()
        nonce=uuid.uuid4().hex;client=str(uuid.uuid4());status,body,_=request('/client/bootstrap?nonce='+nonce,auth=False);envelope=json.loads(body);manifest=json.loads(base64.b64decode(envelope['Payload']));check(status==200 and manifest['Nonce']==nonce and len(manifest['Files'])==6,'Anonymous bootstrap returns a signed task definition')
        status,body,_=request(f'/client/plan?computerName=DEV-PC&clientId={client}&nonce={nonce}',auth=False);plan=json.loads(base64.b64decode(json.loads(body)['Payload']));check(status==200 and len(plan['Configuration']['Printers'])==2 and plan['DistinguishedName'].startswith('CN=DEV-PC,'),'Anonymous plan uses server-side AD targeting')
        check(request(f'/client/plan?computerName=UNKNOWN-PC&clientId={client}&nonce={nonce}',auth=False)[0]==400,'Unknown computer does not receive an empty destructive plan')
        for file in manifest['Files']:
            status,body,_=request('/client/files/'+file['Hash'],auth=False)
            import hashlib
            check(status==200 and hashlib.sha256(body).hexdigest()==file['Hash'],'Signed file hash matches '+file['Path'])
        status,script,_=request('/api/admin/startup.ps1');check(status==200 and b'<RSAKeyValue>' in script and b'__TRANSPORT__' not in script,'Startup script is generated with its pinned public key')
        if os.environ.get('PD_WEB_FIXTURE_OUTPUT'):
            export=pathlib.Path(os.environ['PD_WEB_FIXTURE_OUTPUT']);export.mkdir(parents=True,exist_ok=True);(export/'startup.ps1').write_bytes(script)
            text=script.decode();key=text[text.index('<RSAKeyValue>'):text.index('</RSAKeyValue>')+len('</RSAKeyValue>')]
            (export/'bootstrap-fixture.json').write_text(json.dumps({'Envelope':envelope,'PublicKey':key,'Nonce':nonce,'DeploymentId':deployment}))
        zip_path=data/'vendor.zip'
        inf='[Version]\nClass=Printer\n[Manufacturer]\nVendor=Models,NTamd64,NTarm64\n[Models.NTamd64]\n"Synthetic x64"=Install,ID\n[Models.NTarm64]\n"Synthetic ARM"=Install,ARMID\n'
        with zipfile.ZipFile(zip_path,'w') as z:z.writestr('vendor/printer.inf',inf);z.writestr('vendor/subfolder/binary.dat','not a real driver')
        boundary='pdweb'+uuid.uuid4().hex
        multipart=(f'--{boundary}\r\nContent-Disposition: form-data; name="DriverType"\r\n\r\n3\r\n--{boundary}\r\nContent-Disposition: form-data; name="Package"; filename="vendor.zip"\r\nContent-Type: application/zip\r\n\r\n'.encode()+zip_path.read_bytes()+f'\r\n--{boundary}--\r\n'.encode())
        status,body,_=request('/api/admin/packages','POST',multipart,headers={'Content-Type':'multipart/form-data; boundary='+boundary});check(status==200,'Complete vendor ZIP imports through HTTP and PowerShell INF inspection');package=json.loads(body);check(package['Infs'][0]['Models'][0]['Architectures'] in (['ARM64'],['x64']),'Imported model architecture is exposed');value=state()
        tcp={**printer,'Id':str(uuid.uuid4()),'Name':'Native package queue','Kind':'Type4','Address':'192.0.2.56','PortNumber':9100,'Drivers':{'x64':{'PackageId':package['Id'],'InfPath':'vendor/printer.inf','DriverName':'Synthetic x64','Kind':'Type3'},'ARM64':{'PackageId':package['Id'],'InfPath':'vendor/printer.inf','DriverName':'Synthetic ARM','Kind':'Type3'}}}
        check(request('/api/admin/printers/'+tcp['Id'],'PUT',tcp)[0]==200,'Architecture-specific driver selections are accepted');value=state()
        status,body,_=request(f'/client/plan?computerName=DEV-PC&clientId={client}&nonce={uuid.uuid4().hex}',auth=False);driver_plan=json.loads(base64.b64decode(json.loads(body)['Payload']));check(len(driver_plan['Packages'])==1 and driver_plan['Configuration']['SchemaVersion']==2,'Plan includes referenced package and compatible engine schema')
        status,archive,_=request('/client/packages/'+package['Id']+'/'+package['Sha256'],auth=False);check(status==200 and hashlib.sha256(archive).hexdigest()==package['Sha256'],'Anonymous package download matches signed plan hash')
        report={'SchemaVersion':1,'DeploymentId':deployment,'ComputerName':'DEV-PC','Scope':'Machine','UserSid':'','UserName':'SYSTEM','RunId':str(uuid.uuid4()),'Result':'Failed','ErrorMessage':'Synthetic vendor trust error','InventoryError':'','ReportedAt':'2026-10-14T20:00:00Z','StartedAt':'2026-10-14T19:59:00Z','ConfigurationHash':'a'*64,'Printers':[{'Name':'Old queue','Type':'Local','DriverName':'Old driver','PortName':'Old port','Location':''}],'ConfiguredPrinters':[],'RemovalResults':[]}
        check(request('/client/reports','POST',{'ClientId':client,'ComputerName':'DEV-PC','Report':report},auth=False)[0]==200,'Client reports upload without authentication')
        status,body,_=request('/api/admin/clients');check(status==200 and json.loads(body)[0]['Report']['ErrorMessage']=='Synthetic vendor trust error','Admin inventory exposes received report errors')
        removal={'ComputerName':'DEV-PC','Scope':'Machine','UserSid':'','Name':'Old queue','DriverName':'Old driver','PortName':'Old port','Selected':True}
        check(request('/api/admin/removals','POST',removal)[0]==200,'Administrator can schedule an exact reported queue removal');value=state();request_id=value['Removals'][0]['Id']
        check(request('/api/admin/removals','POST',removal)[0]==200,'Repeated removal selection is accepted');value=state();check(value['Removals'][0]['Id']==request_id,'Removal ID remains stable for one-shot receipts')
        removal['Name']=scoped['Name'];check(request('/api/admin/removals','POST',removal)[0]==400,'Desired printer cannot be selected for deletion')
        print(f'All {checks} HTTP integration checks passed.',flush=True)
    finally:
        process.terminate()
        try:process.wait(timeout=10)
        except subprocess.TimeoutExpired:process.kill();process.wait()
        output.close()
        if process.returncode not in (0,-15):print((data/'server.log').read_text(),file=sys.stderr)
