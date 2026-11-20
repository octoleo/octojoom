<?php
// Minimal Joomla bootstrap for running Octojoom's actual account update PHP.
namespace Joomla\CMS {
    class Factory
    {
        public static $application;

        public static function getContainer()
        {
            return new \FixtureServices();
        }
    }
}

namespace Joomla\CMS\User {
    class UserHelper
    {
        public static function verifyPassword($password, $hash)
        {
            return password_verify($password, $hash);
        }
    }
}

namespace {
    class JConfig
    {
        public $secret = 'test-site-secret';
    }

    class FixtureServices
    {
        public function alias($alias, $service) {}
        public function createExtensionNamespaceMap() {}
        public function get($service) { return $this; }

        public function loadUserByUsername($username)
        {
            $ids = ['owner' => 42, 'second-admin' => 43, 'blocked' => 44, 'member' => 45];
            return new FixtureUser($ids[$username] ?? 0, $username);
        }
    }

    class FixtureUser
    {
        public $id, $username, $email, $block, $password;
        public $name = 'Shop owner';
        private $importedHash;

        public function __construct($id, $username)
        {
            $this->id = $id;
            $this->username = $username;
            $this->email = $username . '@example.test';
            $this->block = $username === 'blocked';
            $this->password = $this->importedHash = password_hash('current-password', PASSWORD_BCRYPT, ['cost' => 4]);
        }

        public function authorise($permission)
        {
            return $this->username !== 'member' && $permission === 'core.login.admin';
        }

        public function bind($changes)
        {
            if (isset($changes['password'])) {
                if ($changes['password'] !== $changes['password2']) {
                    return false;
                }
                $this->password = password_hash($changes['password'], PASSWORD_BCRYPT, ['cost' => 4]);
                unset($changes['password'], $changes['password2']);
            }
            foreach ($changes as $field => $value) {
                $this->$field = $value;
            }
            return true;
        }

        public function save($updateOnly)
        {
            // Every write is observable, including an accidental save on an error path.
            echo json_encode([
                'id' => $this->id, 'username' => $this->username, 'email' => $this->email,
                'keptHash' => $this->password === $this->importedHash,
                'newPasswordWorks' => password_verify('new-password', $this->password),
            ]);
            return $updateOnly;
        }
    }
}
