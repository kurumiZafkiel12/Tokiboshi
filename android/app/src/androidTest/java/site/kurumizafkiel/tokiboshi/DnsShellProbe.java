package site.kurumizafkiel.tokiboshi;

import java.io.ByteArrayOutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;

/** Test APK only. app_process launches this as shell UID, outside the VPN app exclusion. */
public final class DnsShellProbe {
    public static void main(String[] args) throws Exception {
        if (android.os.Process.myUid() != 2000) throw new IllegalStateException("Independent shell UID required");
        ByteArrayOutputStream input = new ByteArrayOutputStream();
        byte[] chunk = new byte[1024];
        int count;
        while ((count = System.in.read(chunk)) != -1) {
            input.write(chunk, 0, count);
            if (input.size() > 4096) throw new IllegalArgumentException("DNS fixture too large");
        }
        byte[] query = input.toByteArray();
        try (DatagramSocket socket = new DatagramSocket()) {
            socket.setSoTimeout(7000);
            socket.connect(InetAddress.getByName("172.19.0.2"), 53);
            socket.send(new DatagramPacket(query, query.length));
            byte[] answer = new byte[4096];
            DatagramPacket response = new DatagramPacket(answer, answer.length);
            socket.receive(response);
            System.out.write(response.getData(), response.getOffset(), response.getLength());
            System.out.flush();
        }
    }
}
