package mxrb.sidecar;

import java.util.LinkedHashMap;
import java.util.Map;

import com.mendix.core.actionmanagement.MicroflowCallBuilder;
import com.mendix.systemwideinterfaces.core.IContext;

/** Core.microflowCall: a microflow of the Ruby application, in the caller's transaction. */
public final class MxMicroflowCall implements MicroflowCallBuilder {
	private final String name;
	private final Map<String, Object> parameters = new LinkedHashMap<>();

	public MxMicroflowCall(String name) {
		this.name = name;
	}

	@Override
	public MicroflowCallBuilder withParam(String parameter, Object value) {
		parameters.put(parameter, value);
		return this;
	}

	@Override
	public MicroflowCallBuilder inTransaction(boolean inTransaction) {
		return this;
	}

	@Override
	@SuppressWarnings("unchecked")
	public <R> R execute(IContext context) {
		return (R) ((MxContext) context).bridge().call("microflow", "name", name, "arguments", parameters);
	}
}
