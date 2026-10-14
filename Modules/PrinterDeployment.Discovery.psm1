Set-StrictMode -Version 2.0

function Initialize-PDDiscovery {
    if ('PrintDeployGPO.Discovery.Scan' -as [type]) { return }
    # One-shot DNS-SD queries (RFC 6762 section 6.7) use ephemeral UDP ports,
    # so discovery can coexist with the Windows mDNS service without binding 5353.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
namespace PrintDeployGPO.Discovery {
    public sealed class Printer {
        public string Name, Host, Address, Protocol, Subpath, Model, Location;
        public int Port;
    }
    public sealed class Record {
        public string Owner, Target;
        public int Type, Port;
        public Dictionary<string,string> Text = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
    }
    public static class DNS {
        static int Number(byte[] packet, ref int cursor) {
            if (cursor < 0 || cursor + 2 > packet.Length) throw new InvalidDataException();
            int value = (packet[cursor] << 8) | packet[cursor+1]; cursor += 2; return value;
        }
        static string Name(byte[] packet, ref int cursor) {
            var labels = new List<string>(); int position = cursor, steps = 0; bool jumped = false;
            while (true) {
                if (position < 0 || position >= packet.Length || ++steps > 128) throw new InvalidDataException();
                int length = packet[position++];
                if (length == 0) { if (!jumped) cursor = position; break; }
                if ((length & 192) == 192) {
                    if (position >= packet.Length) throw new InvalidDataException();
                    int target = ((length & 63) << 8) | packet[position++];
                    if (!jumped) cursor = position; jumped = true; position = target; continue;
                }
                if (length > 63 || position + length > packet.Length) throw new InvalidDataException();
                labels.Add(Encoding.UTF8.GetString(packet,position,length).Replace("\\", "\\\\").Replace(".", "\\.")); position += length;
                if (labels.Sum(x => x.Length + 1) > 255) throw new InvalidDataException();
            }
            return String.Join(".",labels) + ".";
        }
        public static byte[] Query(string name, int type) {
            using (var stream = new MemoryStream()) {
                stream.Write(new byte[] {0,0,0,0,0,1,0,0,0,0,0,0},0,12);
                var labels = new List<string>(); var labelText = new StringBuilder(); bool escaped = false;
                foreach (char c in name) {
                    if (escaped) { labelText.Append(c); escaped=false; }
                    else if (c=='\\') escaped=true;
                    else if (c=='.') { labels.Add(labelText.ToString()); labelText.Clear(); }
                    else labelText.Append(c);
                }
                if (escaped) throw new InvalidDataException();
                if (labelText.Length>0) labels.Add(labelText.ToString());
                foreach (string label in labels) {
                    byte[] value = Encoding.UTF8.GetBytes(label); if (value.Length < 1 || value.Length > 63) throw new InvalidDataException();
                    stream.WriteByte((byte)value.Length); stream.Write(value,0,value.Length);
                }
                stream.WriteByte(0); stream.WriteByte((byte)(type>>8)); stream.WriteByte((byte)type); stream.WriteByte(0); stream.WriteByte(1);
                return stream.ToArray();
            }
        }
        public static Record[] Parse(byte[] packet) {
            var records = new List<Record>();
            try {
                if (packet.Length < 12 || packet.Length > 9000 || (packet[2] & 128) == 0 || (packet[2] & 120) != 0 || packet[0] != 0 || packet[1] != 0 || (packet[3] & 15) != 0) return records.ToArray();
                int cursor = 4, questions = Number(packet,ref cursor), count = Number(packet,ref cursor) + Number(packet,ref cursor) + Number(packet,ref cursor);
                if (questions > 64 || count > 256) return records.ToArray();
                for (int q=0; q<questions; q++) { Name(packet,ref cursor); Number(packet,ref cursor); Number(packet,ref cursor); }
                for (int i=0; i<count; i++) {
                    string owner = Name(packet,ref cursor); int type = Number(packet,ref cursor), cls = Number(packet,ref cursor) & 32767;
                    int ttl1 = Number(packet,ref cursor), ttl2 = Number(packet,ref cursor), length = Number(packet,ref cursor), end = cursor + length;
                    if (end > packet.Length) throw new InvalidDataException();
                    var record = new Record { Owner=owner, Type=type };
                    if (type==12) { record.Target=Name(packet,ref cursor); }
                    else if (type==33 && length>=7) { Number(packet,ref cursor); Number(packet,ref cursor); record.Port=Number(packet,ref cursor); record.Target=Name(packet,ref cursor); }
                    else if (type==16) {
                        while (cursor<end) {
                            int size=packet[cursor++]; if (cursor+size>end) throw new InvalidDataException();
                            string value=Encoding.UTF8.GetString(packet,cursor,size); cursor+=size; int equals=value.IndexOf('=');
                            if (equals>0) record.Text[value.Substring(0,equals)]=value.Substring(equals+1);
                        }
                    } else if (type==1 && length==4) { record.Target=new IPAddress(packet.Skip(cursor).Take(4).ToArray()).ToString(); }
                    if (cursor>end) throw new InvalidDataException();
                    cursor=end;
                    if (cls==1 && (ttl1!=0 || ttl2!=0)) records.Add(record);
                }
            } catch (InvalidDataException) { return new Record[0]; }
            return records.ToArray();
        }
    }
    public sealed class Catalog {
        readonly Dictionary<string,Record> records = new Dictionary<string,Record>(StringComparer.OrdinalIgnoreCase);
        public static readonly string[] Services = { "_ipp._tcp.local.", "_ipps._tcp.local.", "_pdl-datastream._tcp.local." };
        public void Add(byte[] packet) {
            foreach (var record in DNS.Parse(packet)) {
                if (records.Count>=2048) break;
                records[record.Type + ":" + record.Owner + (record.Type==12 ? ":" + record.Target : "")]=record;
            }
        }
        public string[] Questions() {
            var queries = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var ptr in records.Values.Where(r=>r.Type==12 && Services.Contains(r.Owner,StringComparer.OrdinalIgnoreCase))) {
                queries.Add("33|"+ptr.Target); queries.Add("16|"+ptr.Target);
                var srv=records.Values.FirstOrDefault(r=>r.Type==33 && String.Equals(r.Owner,ptr.Target,StringComparison.OrdinalIgnoreCase));
                if (srv!=null && srv.Target!=null && srv.Target.EndsWith(".local.",StringComparison.OrdinalIgnoreCase)) queries.Add("1|"+srv.Target);
            }
            return queries.Take(384).ToArray();
        }
        static string Clean(string value) { return new string((value ?? "").Where(c=>!Char.IsControl(c)).Take(200).ToArray()); }
        public Printer[] Printers() {
            var result = new List<Printer>(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var ptr in records.Values.Where(r=>r.Type==12 && Services.Contains(r.Owner,StringComparer.OrdinalIgnoreCase))) {
                var srv=records.Values.FirstOrDefault(r=>r.Type==33 && String.Equals(r.Owner,ptr.Target,StringComparison.OrdinalIgnoreCase));
                if (srv==null || srv.Port<1 || srv.Port>65535 || String.IsNullOrEmpty(srv.Target)) continue;
                string host=srv.Target.TrimEnd('.'); if (Uri.CheckHostName(host)==UriHostNameType.Unknown) continue;
                var txt=records.Values.FirstOrDefault(r=>r.Type==16 && String.Equals(r.Owner,ptr.Target,StringComparison.OrdinalIgnoreCase));
                var address=records.Values.FirstOrDefault(r=>r.Type==1 && String.Equals(r.Owner,srv.Target,StringComparison.OrdinalIgnoreCase));
                string protocol=ptr.Owner.StartsWith("_ipps.",StringComparison.OrdinalIgnoreCase) ? "ipps" : ptr.Owner.StartsWith("_ipp.",StringComparison.OrdinalIgnoreCase) ? "ipp" : "raw";
                string path="/ipp", model="", location="", value;
                if (txt!=null) {
                    if (txt.Text.TryGetValue("rp",out value) && value.Length>0) path="/"+value.TrimStart('/');
                    if (txt.Text.TryGetValue("ty",out value)) model=Clean(value);
                    if (txt.Text.TryGetValue("note",out value)) location=Clean(value);
                }
                if (path.Length>1024 || path.StartsWith("//") || path.Any(c=>Char.IsControl(c)) || path.Contains("#") || path.Contains("?")) continue;
                string key=host+":"+srv.Port+":"+protocol+":"+path; if (!seen.Add(key)) continue;
                string suffix="."+ptr.Owner;
                string name=ptr.Target.EndsWith(suffix,StringComparison.OrdinalIgnoreCase) ? ptr.Target.Substring(0,ptr.Target.Length-suffix.Length) : host;
                result.Add(new Printer { Name=Clean(name.Replace("\\.",".").Replace("\\\\","\\")),Host=host,Address=protocol=="ipps" ? host : address==null ? host : address.Target,Protocol=protocol,Port=srv.Port,Subpath=path,Model=model,Location=location });
                if (result.Count>=128) break;
            }
            return result.OrderBy(p=>p.Name).ThenBy(p=>p.Protocol).ToArray();
        }
    }
    public sealed class Scan : IDisposable {
        readonly CancellationTokenSource cancel = new CancellationTokenSource();
        public Task<Printer[]> Work { get; private set; }
        public Scan() { Work=Task.Run(()=>Discover(cancel.Token)); }
        static Printer[] Discover(CancellationToken token) {
            var clients=new List<UdpClient>(); var catalog=new Catalog();
            try {
                foreach (var nic in NetworkInterface.GetAllNetworkInterfaces().Where(n=>n.OperationalStatus==OperationalStatus.Up && n.NetworkInterfaceType!=NetworkInterfaceType.Loopback && n.SupportsMulticast)) {
                    foreach (var item in nic.GetIPProperties().UnicastAddresses.Where(a=>a.Address.AddressFamily==AddressFamily.InterNetwork)) {
                        try {
                            var client=new UdpClient(new IPEndPoint(item.Address,0));
                            client.Client.SetSocketOption(SocketOptionLevel.IP,SocketOptionName.MulticastInterface,item.Address.GetAddressBytes());
                            client.Client.SetSocketOption(SocketOptionLevel.IP,SocketOptionName.MulticastTimeToLive,255); clients.Add(client);
                        } catch (SocketException) { }
                        if (clients.Count>=16) break;
                    }
                    if (clients.Count>=16) break;
                }
                if (clients.Count==0) throw new InvalidOperationException("No usable IPv4 multicast network interface. Enter the printer manually or connect to its local network.");
                var timer=Stopwatch.StartNew(); long next=0; int sends=0, packets=0;
                var sent=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                while (timer.ElapsedMilliseconds<6500 && !token.IsCancellationRequested) {
                    if (timer.ElapsedMilliseconds>=next) {
                        foreach (var service in Catalog.Services) Send(clients,DNS.Query(service,12));
                        next+=2000;
                    }
                    foreach (var client in clients) {
                        int drained=0;
                        while (client.Available>0 && drained++<32 && packets++<4096) {
                            IPEndPoint endpoint=new IPEndPoint(IPAddress.Any,0); var packet=client.Receive(ref endpoint);
                            if (endpoint.Port==5353) catalog.Add(packet);
                        }
                    }
                    foreach (var question in catalog.Questions()) {
                        if (sends>=384 || !sent.Add(question)) continue;
                        int split=question.IndexOf('|'); string name=question.Substring(split+1);
                        if (!name.EndsWith(".local.",StringComparison.OrdinalIgnoreCase)) continue;
                        try { Send(clients,DNS.Query(name,Int32.Parse(question.Substring(0,split)))); sends++; } catch (InvalidDataException) { }
                    }
                    Thread.Sleep(25);
                }
                return catalog.Printers();
            } finally { foreach (var client in clients) client.Dispose(); }
        }
        static void Send(List<UdpClient> clients, byte[] packet) {
            foreach (var client in clients) { try { client.Send(packet,packet.Length,new IPEndPoint(IPAddress.Parse("224.0.0.251"),5353)); } catch (SocketException) { } }
        }
        public void Dispose() { cancel.Cancel(); }
    }
}
'@
}
Export-ModuleMember -Function Initialize-PDDiscovery
