package mxrb.sidecar;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * The sidecar: runs the project's Java actions for a Ruby application, one
 * invocation per connection, each on its own thread so an action may call a
 * microflow that runs another Java action.
 */
public final class Server {
	private Server() {
	}

	public static void main(String[] args) throws IOException {
		int port = Integer.parseInt(environment("MXRB_JAVA_ACTIONS_PORT", "7911"));
		String token = System.getenv("MXRB_JAVA_ACTIONS_TOKEN");
		Path report = Path.of(environment("MXRB_JAVA_ACTIONS_REPORT", "build-report.tsv"));
		Invoker invoker = new Invoker(Server.class.getClassLoader(), Invoker.report(report));
		ExecutorService threads = Executors.newCachedThreadPool();
		try (ServerSocket server = new ServerSocket(port)) {
			System.out.println("mxrb Java actions listening on port " + server.getLocalPort());
			while (true) {
				Socket socket = server.accept();
				threads.execute(() -> serve(socket, invoker, token));
			}
		}
	}

	private static void serve(Socket socket, Invoker invoker, String token) {
		try (socket) {
			BufferedReader in = new BufferedReader(
					new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
			BufferedWriter out = new BufferedWriter(
					new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8));
			new Bridge(in, out).serve(invoker, token);
		} catch (IOException | RuntimeException e) {
			System.err.println("mxrb Java actions: " + e);
		}
	}

	private static String environment(String name, String fallback) {
		String value = System.getenv(name);
		return value == null || value.isEmpty() ? fallback : value;
	}
}
