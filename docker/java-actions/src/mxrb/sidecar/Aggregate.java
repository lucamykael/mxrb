package mxrb.sidecar;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import com.mendix.core.CoreException;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixObject;

/** An XPath aggregate: COUNT, SUM, AVG, MIN or MAX of the objects a retrieve finds. */
public final class Aggregate {
	private static final Pattern AGGREGATE = Pattern
			.compile("(?is)\\s*(count|sum|avg|average|min|max)\\s*\\(\\s*(//.+?)\\s*\\)\\s*");

	private Aggregate() {
	}

	/**
	 * The value of an aggregate such as "COUNT(//Module.Entity[...])" or
	 * "SUM(//Module.Entity/Total)", retrieved with the variables; empty values
	 * are left out, as SQL does: the sum of none is 0, their minimum, maximum and
	 * average null.
	 */
	public static BigDecimal compute(IContext context, String aggregate, Map<String, Object> variables)
			throws CoreException {
		Matcher match = AGGREGATE.matcher(aggregate);
		if (!match.matches()) {
			throw new CoreException("unsupported XPath aggregate: " + aggregate);
		}
		String function = match.group(1).toLowerCase(Locale.ROOT);
		String path = match.group(2);
		if (function.equals("count")) {
			return BigDecimal.valueOf(retrieve(context, path, variables).size());
		}
		int slash = path.lastIndexOf('/');
		List<IMendixObject> objects = retrieve(context, path.substring(0, slash), variables);
		String attribute = path.substring(slash + 1);
		BigDecimal result = null;
		int counted = 0;
		for (IMendixObject object : objects) {
			Object value = object.getValue(context, attribute);
			if (value == null) {
				continue;
			}
			counted++;
			BigDecimal number = new BigDecimal(value.toString());
			result = result == null ? number : switch (function) {
			case "min" -> result.min(number);
			case "max" -> result.max(number);
			default -> result.add(number);
			};
		}
		if (result == null) {
			return function.equals("sum") ? BigDecimal.ZERO : null;
		}
		return function.startsWith("av") ? result.divide(BigDecimal.valueOf(counted), 16, RoundingMode.HALF_UP)
				.stripTrailingZeros() : result;
	}

	private static List<IMendixObject> retrieve(IContext context, String path, Map<String, Object> variables) {
		MxXPathQuery query = new MxXPathQuery(path);
		variables.forEach(query::variable);
		return query.execute(context);
	}
}
