package mxrb.sidecar;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

/**
 * The caption keys of enumeration values in proxies Studio Pro generated: each
 * text's id, with the enumeration and the value it captions, from the
 * project at packaging time. Other keys are "Module.Enumeration.value".
 */
public final class Captions {
	private static volatile Map<String, String[]> keys = new HashMap<>();

	private Captions() {
	}

	public static void load(Path path) throws IOException {
		Map<String, String[]> loaded = new HashMap<>();
		if (Files.exists(path)) {
			for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
				String[] fields = line.split("\t");
				if (fields.length == 3) {
					loaded.put(fields[0], new String[] { fields[1], fields[2] });
				}
			}
		}
		keys = loaded;
	}

	/** The enumeration and value of a key, or null for a key that names none. */
	public static String[] resolve(String key) {
		String[] known = keys.get(key);
		if (known != null) {
			return known;
		}
		int dot = key == null ? -1 : key.lastIndexOf('.');
		return dot > 0 && key.indexOf('.') < dot ? new String[] { key.substring(0, dot), key.substring(dot + 1) } : null;
	}

	public static String caption(String language, String key) {
		String[] value = resolve(key);
		if (value == null) {
			return "";
		}
		return (String) Bridge.current().call("caption", "enumeration", value[0], "value", value[1], "language",
				language);
	}
}
