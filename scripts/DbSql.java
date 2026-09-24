import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;

/**
 * Run SQL against the configured database - used by scripts/start-all.sh.
 *
 * There is no psql on most Windows setups and no way to reach the database from
 * the shell otherwise, so this gives local development a way to inspect and
 * repair the schema using the credentials already in backend/.env.
 *
 *   java -cp <postgresql.jar> scripts/DbSql.java "SELECT ..." "UPDATE ..."
 *
 * Statements run in order inside ONE transaction: if any of them fails,
 * everything is rolled back and nothing is changed. Only the statement text is
 * printed (never the credentials).
 *
 * This executes whatever SQL you pass it - treat it like psql: run it against
 * the database you actually intend to change.
 *
 * Exit codes: 0 = all statements succeeded, 1 = a statement failed (rolled back),
 *             2 = missing database configuration.
 */
public class DbSql {

    private static final int MAX_ROWS = 100;

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            System.out.println("usage: java -cp <postgresql.jar> scripts/DbSql.java \"<sql>\" [...]");
            System.out.println("Statements run in a single transaction; the first failure rolls back.");
            System.exit(2);
        }

        String url = required("DB_URL");
        String user = required("DB_USERNAME");
        String password = required("DB_PASSWORD");
        if (url == null || user == null || password == null) {
            System.out.println("MISSING DB_URL / DB_USERNAME / DB_PASSWORD - set them in backend/.env");
            System.exit(2);
        }

        DriverManager.setLoginTimeout(15);

        try (Connection connection = DriverManager.getConnection(url, user, password)) {
            connection.setAutoCommit(false);
            int n = 1;

            for (String sql : args) {
                System.out.println("[" + n++ + "] " + oneLine(sql));
                try (Statement statement = connection.createStatement()) {
                    boolean hasResultSet = statement.execute(sql);
                    if (hasResultSet) {
                        try (ResultSet rs = statement.getResultSet()) {
                            printResultSet(rs);
                        }
                    } else {
                        System.out.println("    " + statement.getUpdateCount() + " row(s) affected");
                    }
                } catch (SQLException e) {
                    System.out.println("    FAILED: " + firstLine(e.getMessage()));
                    connection.rollback();
                    System.out.println("rolled back - no changes were applied");
                    System.exit(1);
                }
            }

            connection.commit();
            System.out.println("committed");
        }
    }

    private static void printResultSet(ResultSet rs) throws SQLException {
        ResultSetMetaData meta = rs.getMetaData();
        int columnCount = meta.getColumnCount();

        StringBuilder header = new StringBuilder("    ");
        for (int i = 1; i <= columnCount; i++) {
            header.append(meta.getColumnLabel(i)).append(i < columnCount ? " | " : "");
        }
        System.out.println(header);

        int rows = 0;
        while (rs.next()) {
            StringBuilder line = new StringBuilder("    ");
            for (int i = 1; i <= columnCount; i++) {
                String value = rs.getString(i);
                if (value == null) value = "NULL";
                if (value.length() > 60) value = value.substring(0, 57) + "...";
                line.append(value).append(i < columnCount ? " | " : "");
            }
            System.out.println(line);
            if (++rows >= MAX_ROWS) {
                System.out.println("    ... (stopped after " + MAX_ROWS + " rows)");
                break;
            }
        }
        if (rows == 0) System.out.println("    (no rows)");
    }

    private static String required(String name) {
        String value = System.getenv(name);
        if (value == null || value.trim().isEmpty()) return null;
        return value;
    }

    private static String oneLine(String sql) {
        String flat = sql.replaceAll("\\s+", " ").trim();
        return flat.length() > 160 ? flat.substring(0, 157) + "..." : flat;
    }

    private static String firstLine(String message) {
        if (message == null) return "unknown error";
        return message.split("\n")[0].trim();
    }
}
