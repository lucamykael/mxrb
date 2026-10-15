package com.mendix.core.actionmanagement;

import java.util.Map;

import com.mendix.systemwideinterfaces.core.IContext;

/** A call of a microflow of the Ruby application. */
public interface MicroflowCallBuilder {
	MicroflowCallBuilder withParam(String name, Object value);

	default MicroflowCallBuilder withParams(Map<String, Object> parameters) {
		parameters.forEach(this::withParam);
		return this;
	}

	MicroflowCallBuilder inTransaction(boolean inTransaction);

	<R> R execute(IContext context);
}
