package com.mendix.core.conf;

import java.io.File;

/** The parts of the application configuration a Java action may read. */
public interface Configuration {
	String getApplicationRootUrl();
	Object getConstantValue(String name);

	default File getTempPath() {
		return new File(System.getProperty("java.io.tmpdir"));
	}

	default File getResourcesPath() {
		return new File(System.getenv().getOrDefault("MXRB_JAVA_ACTIONS_RESOURCES", "resources")).getAbsoluteFile();
	}

	default boolean isInDevelopment() {
		return false;
	}

	/** Where the sidecar runs, in place of the application's directory. */
	default File getBasePath() {
		return new File(System.getProperty("user.dir")).getAbsoluteFile();
	}

	/** Where the sidecar runs, in place of the Runtime's installation directory. */
	default File getRuntimePath() {
		return new File(System.getProperty("user.dir")).getAbsoluteFile();
	}

	/** The administrator the project's security creates. */
	default String getAdminUserName() {
		return (String) security().get("admin_user_name");
	}

	default String getAdminUserRoleName() {
		return (String) security().get("admin_user_role");
	}

	@SuppressWarnings("unchecked")
	private static java.util.Map<String, Object> security() {
		return (java.util.Map<String, Object>) mxrb.sidecar.Bridge.current().call("project_security");
	}

	/** The id of the application's single node. */
	default String getXASId() {
		return "mxrb";
	}

	/** The cookie of the Ruby application's sessions. */
	default String getSessionIdCookieName() {
		return "mxrb_session";
	}

	/** Whether the application's security lets guests in. */
	default boolean getEnableGuestLogin() {
		return Boolean.TRUE.equals(mxrb.sidecar.Bridge.current().call("guest_login_enabled"));
	}
}
