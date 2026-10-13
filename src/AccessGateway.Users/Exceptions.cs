namespace AccessGateway.Users;

/// <summary>O arquivo não é um users_database.yml que o Authelia carregaria com segurança.</summary>
public sealed class UsersDatabaseFormatException(string message, Exception? inner = null) : Exception(message, inner);

public enum UserOperationError
{
    InvalidUsername,
    UserAlreadyExists,
    UserNotFound,
    InvalidDisplayName,
    InvalidEmail,
    EmailAlreadyInUse,
    InvalidGroup,
    UnknownGroup,
    DuplicateGroup,
    InvalidActor,
    SelfDisable,
    SelfAdminRemoval,
    LastAdmin,
}

/// <summary>Operação rejeitada; o banco em memória não foi alterado.</summary>
public sealed class UserOperationException(UserOperationError error, string message) : Exception(message)
{
    public UserOperationError Error { get; } = error;
}

/// <summary>O arquivo mudou desde a leitura (ou durante a escrita); nada foi sobrescrito.</summary>
public sealed class UsersDatabaseConflictException(string message) : Exception(message);

/// <summary>Outra escrita das nossas ferramentas está em andamento; nada foi feito (sem espera).</summary>
public sealed class UsersDatabaseLockedException(string message, Exception? inner = null) : Exception(message, inner);
