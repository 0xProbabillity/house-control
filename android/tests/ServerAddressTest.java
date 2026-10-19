package io.github.housecontrol;
import java.net.URI;
public final class ServerAddressTest {
    private static int assertions;
    public static void main(String[] args) {
        for(String value:new String[]{"https://house.example", "http://192.168.1.2:8787", "http://172.16.0.2", "http://10.0.0.1", "http://house.local", "http://[::1]:8787"}) {ServerAddress.parse(value);assertions++;}
        for(String value:new String[]{"http://house.example", "http://172.32.0.1", "http://192.168.999.1", "https://user:secret@house.example", "https://house.example?token=secret", "https://house.example/#token", "https://house.example/path", "javascript:alert(1)", "file:///etc/passwd", "https://house.example:99999"}) {
            try {ServerAddress.parse(value);throw new AssertionError("Accepted "+value);}catch(IllegalArgumentException expected){assertions++;}
        }
        URI origin=ServerAddress.parse("https://house.example");
        check(ServerAddress.sameOrigin(origin,URI.create("https://house.example:443/api/plan")));
        check(!ServerAddress.sameOrigin(origin,URI.create("http://house.example")));
        check(!ServerAddress.sameOrigin(origin,URI.create("https://other.example")));
        check(!ServerAddress.sameOrigin(origin,URI.create("https://house.example:444")));
        check(!ServerAddress.sameOrigin(origin,URI.create("https://token@house.example")));
        check(!ServerAddress.sameOrigin(origin,URI.create("housecontrol://settings")));
        check(!ServerAddress.sameOrigin(origin,URI.create("javascript:alert(1)")));
        System.out.println("Passed "+assertions+" address and origin policy assertions");
    }
    private static void check(boolean ok){assertions++;if(!ok)throw new AssertionError();}
}
