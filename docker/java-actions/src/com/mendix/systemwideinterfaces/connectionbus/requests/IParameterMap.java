package com.mendix.systemwideinterfaces.connectionbus.requests;

import java.util.List;

/** The values of an OQL query's $parameters. */
public interface IParameterMap {
	void put(String name, Object value);
	void putCollection(String name, List<?> values);
}
