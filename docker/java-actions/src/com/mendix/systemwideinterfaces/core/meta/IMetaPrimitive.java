package com.mendix.systemwideinterfaces.core.meta;

import java.util.Collection;

/** An attribute of an entity. */
public interface IMetaPrimitive extends IMetaObjectMember {
	/** The type of an attribute. */
	enum PrimitiveType { AutoNumber, Binary, Boolean, DateTime, Decimal, Enum, Integer, Long, String, HashString }

	String getDefaultValue();
	boolean isVirtual();
	int getLength();
	IMetaObject getParent();
	PrimitiveType getType();
	Collection<? extends IMetaEnumValue> getEnumValues();
	IMetaEnumeration getEnumeration();
	boolean isDecimal();
	boolean isNumeric();
}
