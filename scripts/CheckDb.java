import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * Quick database credential check for scripts/start-all.sh (the `db` command).
 *
 * Why this exists: an invalid password makes the backend abort during startup
 * (hibernate runs ddl-auto=update, which needs a connection), and restarting
 * the whole stack just to test a password is slow. This connects twice so the
 * output tells you WHICH value is wrong:
 *
 *   A) the URL exactly as configured - this mirrors what Spring Boot does when
 *      it calls DriverManager.getConnection(url, user, password)
 *   B) the same URL with any inline user=/password= parameters removed, so only
 *      DB_USERNAME / DB_PASSWORD are used
 *
 * If A fails but B succeeds, the stale value is the one embedded in DB_URL.
 * If both fail, the credentials themselves are wrong.
 *
 * Exit codes: 0 = connected, 1 = rejected or unreachable, 2 = missing config.
 *
 * Runs with no third-party code (java.sql only); the PostgreSQL driver jar is
 * supplied on the classpath by start-all.sh.
 */
public class CheckDb {

    public static void main(String[] args) {
        String url = env("DB_URL");
        String user = env("DB_USERNAME");
        String password = env("DB_PASSWORD");

        if (url == null || user == null || password == null) {
            List<String> missing = new ArrayList<>();
            if (url == null) missing.add("DB_URL");
            if (user == null) missing.add("DB_USERNAME");
            if (password == null) missing.add("DB_PASSWORD");
            System.out.println("MISSING " + String.join(", ", missing)
                    + " - set them in backend/.env or the root .env");
            System.exit(2);
        }

        DriverManager.setLoginTimeout(15);

        String stripped = stripCredentials(url);
        String inlineUser = queryParam(url, "user");
        String inlinePassword = queryParam(url, "password");
        boolean inlineDiffers = (inlinePassword != null && !inlinePassword.equals(password))
                || (inlineUser != null && !inlineUser.equals(user));

        // A - exactly what the backend does
        String errorA = attempt(url, user, password);
        if (errorA == null) {
            ok("connection accepted", user, stripped);
            if (inlineDiffers) {
                System.out.println("NOTE: DB_URL also embeds user=/password= and they do NOT match"
                        + " DB_USERNAME/DB_PASSWORD.");
                System.out.println("      Remove them from DB_URL so the two can never drift apart.");
            }
            System.exit(0);
        }

        // B - inline credentials removed, only DB_USERNAME/DB_PASSWORD remain
        String errorB = attempt(stripped, user, password);
        if (errorB == null) {
            System.out.println("REJECTED as configured, but the credentials themselves are valid.");
            System.out.println("The stale value is the user=/password= embedded in DB_URL.");
            System.out.println("Fix: delete the inline user=... and password=... parameters from DB_URL.");
            System.exit(1);
        }

        System.out.println("FAILED: " + summary(errorA));
        if (inlineDiffers && !errorA.equals(errorB)) {
            System.out.println("Without the inline credentials the error differs: " + summary(errorB));
        }
        System.out.println();
        if (looksLikeAuth(errorA) || looksLikeAuth(errorB)) {
            System.out.println("The database rejected the credentials for user '" + user + "'.");
            System.out.println("  1. Neon console -> your project -> Connection Details -> copy the password");
            System.out.println("     (or Settings -> Reset password for neondb_owner)");
            System.out.println("  2. Put it in DB_PASSWORD in backend/.env");
            System.out.println("  3. Remove any inline user=/password= from DB_URL");
            System.out.println("  4. Re-run: ./scripts/start-all.sh db");
        } else {
            System.out.println("This looks like a network/SSL problem rather than a bad password:");
            System.out.println("  - DB_URL host must be reachable from this machine");
            System.out.println("  - keep ?sslmode=require for NeonDB");
            System.out.println("  - check the value in backend/.env");
        }
        System.exit(1);
    }

    /** Returns null when the connection succeeded, otherwise the failure message. */
    private static String attempt(String url, String user, String password) {
        try (Connection connection = DriverManager.getConnection(url, user, password)) {
            if (!connection.isValid(10)) {
                return "connection opened but isValid() returned false";
            }
            return null;
        } catch (SQLException e) {
            return e.getMessage();
        }
    }

    private static void ok(String what, String user, String url) {
        System.out.println("CONNECTED: " + what);
        System.out.println("  user: " + user);
        System.out.println("  url : " + url);
    }

    private static String summary(String message) {
        if (message == null) return "unknown error";
        return message.split("\n")[0].trim();
    }

    private static boolean looksLikeAuth(String message) {
        if (message == null) return false;
        String m = message.toLowerCase();
        return m.contains("password authentication failed")
                || m.contains("authentication failed")
                || m.contains("role")
                || m.contains("password")
                || m.contains("28p01")
                || m.contains("28000");
    }

    private static String env(String name) {
        String value = System.getenv(name);
        if (value == null || value.trim().isEmpty()) return null;
        return value;
    }

    /** Removes user=... and password=... parameters from a JDBC URL. */
    private static String stripCredentials(String url) {
        int q = url.indexOf('?');
        if (q < 0) return url;
        String base = url.substring(0, q);
        List<String> kept = new ArrayList<>();
        for (String part : url.substring(q + 1).split("&")) {
            if (part.isEmpty()) continue;
            String name = part.split("=", 2)[0];
            if (name.equals("user") || name.equals("password")) continue;
            kept.add(part);
        }
        if (kept.isEmpty()) return base;
        return base + "?" + String.join("&", kept);
    }

    private static String queryParam(String url, String name) {
        int q = url.indexOf('?');
        if (q < 0) return null;
        for (String part : url.substring(q + 1).split("&")) {
            String[] pair = part.split("=", 2);
            if (pair.length == 2 && pair[0].equals(name)) return pair[1];
        }
        return null;
    }
}
