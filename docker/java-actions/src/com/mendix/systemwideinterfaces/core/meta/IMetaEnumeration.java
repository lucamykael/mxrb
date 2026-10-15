package com.mendix.systemwideinterfaces.core.meta;

import java.util.Map;

/** An enumeration and its values by identifier. */
public interface IMetaEnumeration {
	String getName();
	Map<String, IMetaEnumValue> getEnumValues();
}
