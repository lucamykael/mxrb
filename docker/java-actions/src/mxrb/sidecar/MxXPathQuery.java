package mxrb.sidecar;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.mendix.datastorage.XPathQuery;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;

/** Core.createXPathQuery: a retrieve the Ruby application evaluates. */
public final class MxXPathQuery implements XPathQuery {
	private final String xpath;
	private final Map<String, Object> variables = new LinkedHashMap<>();
	private final List<Object> sort = new ArrayList<>();
	private int amount = -1;
	private int offset;

	public MxXPathQuery(String xpath) {
		this.xpath = xpath;
	}

	@Override
	public XPathQuery setAmount(int amount) {
		this.amount = amount;
		return this;
	}

	@Override
	public XPathQuery setOffset(int offset) {
		this.offset = offset;
		return this;
	}

	@Override
	public XPathQuery addSort(String path, boolean ascending) {
		sort.add(List.of(path, !ascending));
		return this;
	}

	@Override
	public XPathQuery setDepth(int depth) {
		return this;
	}

	@Override
	public XPathQuery setVariable(String name, BigDecimal value) {
		return variable(name, value);
	}

	@Override
	public XPathQuery setVariable(String name, boolean value) {
		return variable(name, value);
	}

	@Override
	public XPathQuery setVariable(String name, double value) {
		return variable(name, BigDecimal.valueOf(value));
	}

	@Override
	public XPathQuery setVariable(String name, int value) {
		return variable(name, (long) value);
	}

	@Override
	public XPathQuery setVariable(String name, long value) {
		return variable(name, value);
	}

	@Override
	public XPathQuery setVariable(String name, IMendixObject value) {
		return variable(name, value);
	}

	@Override
	public XPathQuery setVariable(String name, IMendixIdentifier value) {
		return variable(name, value == null ? null : value.getObject());
	}

	@Override
	public XPathQuery setVariable(String name, String value) {
		return variable(name, value);
	}

	@Override
	public XPathQuery setVariable(String name, Date value) {
		return variable(name, value);
	}

	@Override
	@SuppressWarnings("unchecked")
	public List<IMendixObject> execute(IContext context) {
		return (List<IMendixObject>) ((MxContext) context).bridge().call("retrieve", "xpath", xpath, "variables",
				variables, "offset", (long) offset, "amount", (long) amount, "sort", sort);
	}

	private XPathQuery variable(String name, Object value) {
		variables.put(name.startsWith("$") ? name.substring(1) : name, value);
		return this;
	}
}
