package mxrb.sidecar;

import java.io.IOException;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import com.mendix.core.CoreRuntimeException;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.UserAction;

/** Constructs a project's Java action with its parameters and executes it. */
public final class Invoker {
	private final ClassLoader loader;
	private final Map<String, String> excluded;

	public Invoker(ClassLoader loader, Map<String, String> excluded) {
		this.loader = loader;
		this.excluded = excluded;
	}

	/** The classes the build left out, with the compiler error that excluded each. */
	public static Map<String, String> report(Path path) throws IOException {
		Map<String, String> excluded = new HashMap<>();
		if (!Files.exists(path)) {
			return excluded;
		}
		for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
			int tab = line.indexOf('\t');
			if (tab > 0) {
				excluded.put(line.substring(0, tab), line.substring(tab + 1));
			}
		}
		return excluded;
	}

	/** "Module.Action" is the class module.actions.Action, as Studio Pro generates it. */
	public static String className(String action) {
		int dot = action.indexOf('.');
		if (dot <= 0 || dot == action.length() - 1) {
			throw new IllegalArgumentException("not a qualified Java action name: " + action);
		}
		return action.substring(0, dot).toLowerCase(Locale.ROOT) + ".actions." + action.substring(dot + 1);
	}

	public Object invoke(IContext context, String action, List<Object[]> arguments) throws Exception {
		String name = className(action);
		Class<?> type;
		try {
			type = Class.forName(name, true, loader);
		} catch (ClassNotFoundException e) {
			String reason = excluded.get(name);
			throw new CoreRuntimeException("Java action " + action + " is not available in the sidecar: "
					+ (reason == null ? "no class " + name : "it does not compile: " + reason));
		}
		Constructor<?> constructor = constructor(type, arguments.size() + 1);
		Class<?>[] types = constructor.getParameterTypes();
		Object[] values = new Object[types.length];
		values[0] = context;
		for (int i = 0; i < arguments.size(); i++) {
			values[i + 1] = convert(arguments.get(i)[1], types[i + 1], action, (String) arguments.get(i)[0]);
		}
		UserAction<?> instance;
		try {
			instance = (UserAction<?>) constructor.newInstance(values);
		} catch (InvocationTargetException e) {
			throw e.getCause() instanceof Exception cause ? cause : e;
		}
		return instance.execute();
	}

	private static Constructor<?> constructor(Class<?> type, int count) {
		if (!UserAction.class.isAssignableFrom(type)) {
			throw new CoreRuntimeException(type.getName() + " is not a Java action");
		}
		for (Constructor<?> constructor : type.getConstructors()) {
			Class<?>[] types = constructor.getParameterTypes();
			if (types.length == count && types[0].isAssignableFrom(MxContext.class)) {
				return constructor;
			}
		}
		throw new CoreRuntimeException(type.getName() + " has no constructor for " + (count - 1) + " parameters");
	}

	private static Object convert(Object value, Class<?> type, String action, String parameter) {
		if (value == null || type.isInstance(value)) {
			return value;
		}
		if (value instanceof Long number) {
			if (type == Integer.class) {
				return number.intValue();
			}
			if (type == BigDecimal.class) {
				return BigDecimal.valueOf(number);
			}
		}
		if (value instanceof Integer number && type == Long.class) {
			return number.longValue();
		}
		throw new IllegalArgumentException("Java action " + action + " parameter " + parameter + " expects "
				+ type.getName() + ", got " + value.getClass().getName());
	}
}
