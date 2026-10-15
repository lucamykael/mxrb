package mxrb.sidecar;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import javax.tools.Diagnostic;
import javax.tools.DiagnosticCollector;
import javax.tools.JavaCompiler;
import javax.tools.JavaFileObject;
import javax.tools.StandardJavaFileManager;
import javax.tools.ToolProvider;

/**
 * Compiles a project's javasource against the sidecar's Runtime API and the
 * project's userlib. A source that does not compile, because it uses an API
 * the sidecar does not offer, is left out with its first error in the report,
 * and the rest is compiled again; an action left out fails when it is called.
 *
 * Usage: Build javasource userlib classes report.tsv
 */
public final class Build {
	private Build() {
	}

	public static void main(String[] args) throws IOException {
		if (args.length != 4) {
			System.err.println("usage: Build javasource userlib classes report.tsv");
			System.exit(2);
		}
		Path sources = Path.of(args[0]);
		Path classes = Path.of(args[2]);
		List<Path> remaining = files(sources, ".java");
		String classpath = classpath(Path.of(args[1]));
		JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
		Map<Path, String> excluded = new LinkedHashMap<>();
		while (!remaining.isEmpty()) {
			delete(classes);
			Files.createDirectories(classes);
			DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();
			try (StandardJavaFileManager files = compiler.getStandardFileManager(diagnostics, Locale.ROOT,
					StandardCharsets.UTF_8)) {
				List<String> options = List.of("-d", classes.toString(), "-cp", classpath, "-encoding", "UTF-8",
						"-parameters", "-proc:none", "-nowarn", "-Xmaxerrs", "100000");
				boolean compiled = compiler
						.getTask(null, files, diagnostics, options, null, files.getJavaFileObjectsFromPaths(remaining))
						.call();
				if (compiled) {
					break;
				}
			}
			Map<Path, String> failing = errors(diagnostics);
			if (failing.isEmpty()) {
				throw new IllegalStateException("javac failed without a source error: " + diagnostics.getDiagnostics());
			}
			excluded.putAll(failing);
			remaining.removeAll(failing.keySet());
		}
		if (remaining.isEmpty()) {
			delete(classes);
			Files.createDirectories(classes);
		}
		StringBuilder report = new StringBuilder();
		excluded.forEach((source, error) -> report.append(className(sources, source)).append('\t').append(error)
				.append('\n'));
		Files.writeString(Path.of(args[3]), report, StandardCharsets.UTF_8);
		System.out.println("compiled " + remaining.size() + " sources, left out " + excluded.size());
	}

	private static Map<Path, String> errors(DiagnosticCollector<JavaFileObject> diagnostics) {
		Map<Path, String> failing = new LinkedHashMap<>();
		for (Diagnostic<? extends JavaFileObject> diagnostic : diagnostics.getDiagnostics()) {
			if (diagnostic.getKind() == Diagnostic.Kind.ERROR && diagnostic.getSource() != null) {
				Path source = Path.of(diagnostic.getSource().toUri()).toAbsolutePath().normalize();
				failing.putIfAbsent(source, "line " + diagnostic.getLineNumber() + ": "
						+ diagnostic.getMessage(Locale.ROOT).replaceAll("\\s+", " ").strip());
			}
		}
		return failing;
	}

	private static String className(Path root, Path source) {
		String relative = root.toAbsolutePath().normalize().relativize(source).toString();
		return relative.substring(0, relative.length() - ".java".length()).replace('/', '.').replace('\\', '.');
	}

	private static String classpath(Path userlib) throws IOException {
		List<String> entries = new ArrayList<>();
		entries.add(System.getProperty("java.class.path"));
		for (Path jar : files(userlib, ".jar")) {
			entries.add(jar.toString());
		}
		return String.join(java.io.File.pathSeparator, entries);
	}

	private static List<Path> files(Path root, String extension) throws IOException {
		if (!Files.isDirectory(root)) {
			return new ArrayList<>();
		}
		try (Stream<Path> paths = Files.walk(root)) {
			return paths.filter(path -> path.toString().endsWith(extension) && Files.isRegularFile(path))
					.map(path -> path.toAbsolutePath().normalize()).sorted()
					.collect(Collectors.toCollection(ArrayList::new));
		}
	}

	private static void delete(Path root) throws IOException {
		if (!Files.exists(root)) {
			return;
		}
		try (Stream<Path> paths = Files.walk(root)) {
			paths.sorted(Comparator.reverseOrder()).forEach(path -> {
				try {
					Files.delete(path);
				} catch (IOException e) {
					throw new UncheckedIOException(e);
				}
			});
		}
	}
}
