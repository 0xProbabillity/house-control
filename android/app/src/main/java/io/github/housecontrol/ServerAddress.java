package io.github.housecontrol;
import java.net.URI;
import java.util.Locale;

/** Only an origin is accepted; credentials and tokens never become navigation URLs. */
public final class ServerAddress {
    public static URI parse(String input) {
        URI uri;
        try { uri = URI.create(input.trim()); } catch (IllegalArgumentException e) { throw invalid(); }
        String scheme = uri.getScheme(), host = uri.getHost();
        if (scheme == null || host == null || uri.getUserInfo() != null || uri.getRawQuery() != null
            || uri.getRawFragment() != null || !(uri.getPath() == null || uri.getPath().isEmpty() || uri.getPath().equals("/"))
            || uri.getPort() == 0 || uri.getPort() > 65535) throw invalid();
        scheme = scheme.toLowerCase(Locale.ROOT);
        if (!scheme.equals("https") && !(scheme.equals("http") && privateHost(host))) throw invalid();
        return URI.create(scheme + "://" + host.toLowerCase(Locale.ROOT) + (uri.getPort() < 0 ? "" : ":" + uri.getPort()));
    }
    public static boolean privateHost(String value) {
        String host = value.toLowerCase(Locale.ROOT);
        if (host.equals("localhost") || host.endsWith(".local") || host.equals("[::1]")) return true;
        if (host.startsWith("[fc") || host.startsWith("[fd") || host.startsWith("[fe80:")) return true;
        String[] parts = host.split("\\.");
        if (parts.length != 4) return false;
        int[] n = new int[4];
        try { for (int i=0;i<4;i++) { if (!parts[i].matches("[0-9]{1,3}")) return false; n[i]=Integer.parseInt(parts[i]); if(n[i]>255) return false; } }
        catch (NumberFormatException e) { return false; }
        return n[0]==10 || n[0]==127 || (n[0]==192 && n[1]==168) || (n[0]==172 && n[1]>=16 && n[1]<=31);
    }
    public static boolean sameOrigin(URI base, URI other) {
        return other.getHost()!=null && other.getScheme()!=null && base.getScheme().equalsIgnoreCase(other.getScheme()) && base.getHost().equalsIgnoreCase(other.getHost()) && port(base)==port(other) && other.getUserInfo()==null;
    }
    private static int port(URI u) { return u.getPort()<0 ? ("https".equals(u.getScheme()) ? 443 : 80) : u.getPort(); }
    private static IllegalArgumentException invalid() { return new IllegalArgumentException("Enter an HTTPS server address, or HTTP on a private IP, localhost or .local host. Use the address only, with no path, password or token."); }
}
