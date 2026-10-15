package com.mendix.systemwideinterfaces.core.meta;

/** A value of an enumeration; its caption is Core.getInternationalizedString of its key. */
public interface IMetaEnumValue {
	IMetaEnumeration getEnumeration();
	String getIdentifier();
	String getI18NCaptionKey();
	String getImage();
}
